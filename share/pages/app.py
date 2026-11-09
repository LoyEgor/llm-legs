"""The chats app on the pages server: Egor's live Mac chats on the iPad, every account in one list.

A chat is never resumed or re-spawned: what he types goes into the same Terminal tab the chat already runs in, so the
same process answers on the same account with its prompt cache still warm. Reading is files (the session registry,
the transcript, memlogd's chats.json); every touch of Terminal goes through Hammerspoon's ChatGate.terminalScript,
the one bounded AppleScript path (Hammerspoon already holds the Automation grant, the launchd daemon does not), and
the menubar mirror is llm-limits' read-only menuItems(). The interface is CONTRACT.md "App".
"""

import glob
import importlib.machinery
import importlib.util
import json
import os
import re
import shlex
import signal
import socket
import subprocess
import sys
import tempfile
import threading
import time
import zlib

KIT = ""  # set by bin/page: <repo>/share/pages/kit, read from the main checkout even by the deployed daemon
store = None  # bin/page's store module

SESSIONS = os.environ.get("APP_SESSIONS")  # a test's registry dir; else chat_names.session_store_files()
CHATS_JSON = os.environ.get("APP_CHATS_JSON") or os.path.expanduser("~/Library/Logs/memlogd/chats.json")
HS = os.environ.get("APP_HS") or "/opt/homebrew/bin/hs"
LOG_WINDOW = 768 << 10
RESULT_CAP = 2400
TEXT_CAP = 60000
SEND_CAP = 200 << 10
TTY_RE = re.compile(r"^/dev/ttys[0-9]{1,4}$")
SID_RE = re.compile(r"^[A-Za-z0-9-]{8,80}$")
ENV_RE = re.compile(r"(?:^|\s)(CLAUDE_LIMITS_ACCOUNT|CLAUDE_CONFIG_DIR|CLAUDEGPT_ACCOUNT)=(\S*)")
FORK_RE = re.compile(r"\s--resume[= ]([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})\b.*\s--fork-session\b")
LOAD_RE = re.compile(r"^(.{11})(.*?)\s+([0-9.]+) cores\s+([0-9.]+) GB\s*(.*)$")
PASTED_RE = re.compile(r"<pasted_content id=[^>]*>(.*?)</pasted_content id=[^>]*>", re.S)
TAG_RE = re.compile(r"<(command-name|command-args|local-command-stdout|local-command-stderr|bash-input|bash-stdout|"
                    r"bash-stderr|command-message)>(.*?)</\1>", re.S)
MACHINERY = ("<system-reminder>", "Caveat:", "<local-command-caveat>")
HS_LOCK = threading.Lock()
CACHE = {}
CACHE_LOCK = threading.Lock()


def repo():
    return os.path.dirname(os.path.dirname(os.path.dirname(os.path.realpath(KIT))))


def static_dir():
    return os.path.join(os.path.dirname(os.path.realpath(KIT)), "app")


def cached(key, ttl, make):
    """make() at most once per ttl seconds per key; concurrent callers share the one answer."""
    with CACHE_LOCK:
        held = CACHE.get(key)
        if held and time.time() - held[0] < ttl:
            return held[1]
    value = make()
    with CACHE_LOCK:
        CACHE[key] = (time.time(), value)
    return value


FAILED = {}  # argv[0] -> why its last call failed, for the error an endpoint answers with


def run(argv, timeout=5, env=None):
    try:
        done = subprocess.run(argv, capture_output=True, text=True, timeout=timeout, env=env,
                              stdin=subprocess.DEVNULL)  # hs -c reads an open stdin and never returns
    except (OSError, subprocess.TimeoutExpired) as error:
        FAILED[argv[0]] = str(error)[:200]
        return None
    if done.returncode != 0:
        FAILED[argv[0]] = "exit %d: %s" % (done.returncode, (done.stderr or done.stdout).strip()[:200])
        return None
    return done.stdout


# ---------------------------------------------------------------- the live chats

def shared(name):
    """A module of the repo's share/ (chat_names), imported once."""
    if name not in sys.modules:
        folder = os.path.join(repo(), "share")
        if folder not in sys.path:
            sys.path.append(folder)
    return __import__(name)


def registry():
    """pid -> the session registry record of every claude process this Mac knows (the same file shows up in
    every profile through the shared symlink)."""
    found = {}
    paths = glob.glob(os.path.join(SESSIONS, "*.json")) if SESSIONS else shared("chat_names").session_store_files()
    for path in paths:
        try:
            with open(path, encoding="utf-8") as handle:
                doc = json.load(handle)
        except (OSError, ValueError):
            continue
        if isinstance(doc, dict) and isinstance(doc.get("pid"), int) and doc.get("sessionId"):
            found.setdefault(doc["pid"], doc)
    return found


def processes(pids):
    """pid -> (tty, lstart) of the live ones, lstart in the registry's own format (C locale, UTC)."""
    if not pids:
        return {}
    env = dict(os.environ, LC_ALL="C", TZ="UTC")
    out = run(["ps", "-o", "pid=,tty=,lstart=", "-p", ",".join(str(p) for p in pids)], env=env) or ""
    live = {}
    for line in out.splitlines():
        parts = line.split(None, 2)
        if len(parts) == 3 and parts[0].isdigit():
            live[int(parts[0])] = (parts[1], " ".join(parts[2].split()))
    return live


ACCOUNTS = {}
FORKS = {}  # pid -> the session a `--resume <sid> --fork-session` process branched from (read with its account)
CUTS = {}  # pid -> (parent transcript, byte offset): how far the parent went when the branch began


def accounts(started):
    """{pid: lstart} -> {pid: (vendor, account)} from each process's own environment, by share/chat-account.sh's
    order: the claudegpt gateway, then CLAUDE_LIMITS_ACCOUNT, then the config dir's name. Read once per process
    (pid + start time: a reused pid is another process)."""
    for pid in [p for p, held in ACCOUNTS.items() if started.get(p, held[0]) != held[0]]:
        del ACCOUNTS[pid]
        FORKS.pop(pid, None)
        CUTS.pop(pid, None)
    missing = [p for p in started if p not in ACCOUNTS]
    if missing:
        out = run(["ps", "-E", "-o", "pid=,command=", "-p", ",".join(str(p) for p in missing)]) or ""
        for line in out.splitlines():
            head, _, rest = line.strip().partition(" ")
            if not head.isdigit():
                continue
            env, pid = dict(ENV_RE.findall(rest)), int(head)
            if pid not in started:
                continue
            fork = FORK_RE.search(" " + rest)
            if fork:
                FORKS[pid] = fork.group(1)
            gateway, named, config = (env.get("CLAUDEGPT_ACCOUNT"), env.get("CLAUDE_LIMITS_ACCOUNT"),
                                      env.get("CLAUDE_CONFIG_DIR"))
            if gateway and gateway != "-":
                found = ("codex", gateway)
            elif named and named != "-":
                found = ("claude", named)
            elif config and os.path.realpath(config) != os.path.realpath(os.path.expanduser("~/.claude")):
                found = ("claude", os.path.basename(config.rstrip("/")))
            else:
                found = ("claude", "")
            ACCOUNTS[pid] = (started[pid], found)
    return {p: ACCOUNTS[p][1] if p in ACCOUNTS else ("claude", "") for p in started}


def recent(sessions=()):
    """session -> chat-find's row (name, transcript path, ctx, model, when it last spoke, cache ttl); sessions: just
    those, whenever they last spoke."""
    finder = os.environ.get("APP_CHAT_FIND") or os.path.join(repo(), "bin", "chat-find")
    out = run([sys.executable, finder, "--recent", "--json"] + [a for sid in sessions for a in ("--session", sid)], timeout=8)
    try:
        rows = json.loads(out) if out else []
    except ValueError:
        rows = []
    return {r["session"]: r for r in rows if isinstance(r, dict) and r.get("session")}


_CHATS_MODULE = []


def warm(row):
    """bin/chats' warm_account: the account whose prompt cache holds the chat, and row["until"]."""
    if not _CHATS_MODULE:
        try:
            loader = importlib.machinery.SourceFileLoader("chats_picker", os.path.join(repo(), "bin", "chats"))
            spec = importlib.util.spec_from_loader("chats_picker", loader)
            module = importlib.util.module_from_spec(spec)
            loader.exec_module(module)
            _CHATS_MODULE.append(module)
        except Exception:
            _CHATS_MODULE.append(None)
    module = _CHATS_MODULE[0]
    if module is None or not row.get("session"):
        return None
    try:
        return module.warm_account(row)
    except Exception:
        return None


def load():
    """memlogd's chats.json: the machine's CPU/memory header and each chat's state, cores, GB and sparkline."""
    try:
        with open(CHATS_JSON, encoding="utf-8") as handle:
            doc = json.load(handle)
    except (OSError, ValueError):
        return {}, {}
    per, header = {}, []
    for row in doc.get("rows") or []:
        if not isinstance(row, dict):
            continue
        m = LOAD_RE.match(row.get("text") or "")
        if row.get("session") and m:
            per[row["session"]] = {"state": m.group(1).strip(), "cores": float(m.group(3)),
                                   "gb": float(m.group(4)), "spark": m.group(5)}
        elif row.get("text", "").startswith(("CPU", "Mem")):
            header.append(row["text"])
    machine = {"title": doc.get("title") or "", "lines": header, "as_of": doc.get("as_of"),
               "alarm": bool(doc.get("alarm"))}
    return machine, per


def tail_lines(path, size, cut=None):
    try:
        with open(path, "rb") as handle:
            end = handle.seek(0, 2) if cut is None else cut
            start = max(0, end - size)
            handle.seek(start)
            data = handle.read(end - start)
    except OSError:
        return []
    if start:
        data = data.partition(b"\n")[2]
    return data.splitlines()


def headline(path, cut=None):
    """The chat's latest recap (Claude's away_summary) and its last spoken line, from the transcript's tail (the
    bytes before `cut`)."""
    away, last = None, None
    for raw in reversed(tail_lines(path, 256 << 10, cut)):
        try:
            entry = json.loads(raw)
        except ValueError:
            continue
        if away is None and entry.get("type") == "system" and entry.get("subtype") == "away_summary":
            away = (entry.get("content") or "")[:400]
        if last is None and not entry.get("isSidechain"):
            for item in parse_entry(entry):
                if item["k"] in ("user", "asst"):
                    last = {"role": item["k"], "t": item["t"][:300]}
                    break
        if away is not None and last is not None:
            break
    return away, last


def cut_at(path, ms):
    """The end of the last line of `path` stamped no later than epoch `ms` (milliseconds): the transcript as it stood
    then, it only grows. Read back from the end, a MB at a time."""
    since = time.strftime("%Y-%m-%dT%H:%M:%S", time.gmtime(ms // 1000)) + ".%03dZ" % (ms % 1000)
    with open(path, "rb") as handle:
        pos, carry = handle.seek(0, 2), b""
        while pos > 0:
            step = min(pos, 1 << 20)
            pos -= step
            handle.seek(pos)
            data = handle.read(step) + carry
            first = data.find(b"\n") + 1 if pos else 0
            if pos and not first:
                carry = data
                continue
            stop = pos + len(data)
            for line in reversed(data[first:].splitlines(True)):
                try:
                    stamp = json.loads(line).get("timestamp")
                except (ValueError, AttributeError):
                    stamp = None
                if isinstance(stamp, str) and stamp <= since:
                    return stop
                stop -= len(line)
            carry = data[:first]
    return 0


def branch_source(rec):
    """A live branch with no transcript of its own yet: (the parent's transcript, where it stood when the branch
    began) or (None, None)."""
    parent = FORKS.get(rec["pid"])
    path = parent and transcript(parent)
    if not path:
        return None, None
    held = CUTS.get(rec["pid"])
    if not held or held[0] != path:
        try:
            held = CUTS[rec["pid"]] = (path, cut_at(path, int(rec.get("startedAt") or 0)))
        except OSError:
            return None, None
    return held


def transcript(sid, row=None):
    path = (row or {}).get("path")
    if path and os.path.exists(path):
        return path
    try:
        found = shared("chat_names").transcript_path(sid)
        return str(found) if found else None
    except Exception:
        return None


def live():
    """The live claude processes: [(record, tty, vendor, account)], workers (no tty) included."""
    return cached("live", 1.5, scan)


def scan():
    records = registry()
    procs = processes(sorted(records))
    out = []
    for pid, rec in records.items():
        proc = procs.get(pid)
        if not proc or (rec.get("procStart") and " ".join(rec["procStart"].split()) != proc[1]):
            continue
        tty = "/dev/" + proc[0] if proc[0] not in ("??", "-") else None
        out.append((rec, tty))
    names = accounts({rec["pid"]: procs[rec["pid"]][1] for rec, _ in out})
    return [(rec, tty) + names[rec["pid"]] for rec, tty in out]


HEADLINES = {}
PATHS = {}
CUT_AT = {}  # sid -> the byte its transcript is read up to (a branch reading its parent)


def chats():
    found = recent()
    machine, per = load()
    rows, workers = [], []
    pages_by = {}
    if store is not None:
        for sid in os.listdir(os.path.join(store.root(), ".by-session")) if os.path.isdir(
                os.path.join(store.root(), ".by-session")) else []:
            pages_by[sid] = len(store.owner_pages(sid))
    for rec, tty, vendor, account in live():
        sid = rec["sessionId"]
        row = dict(found.get(sid) or {"session": sid})
        warm_in = warm(row)
        # A branch writes its transcript with its first message (Egor 2026-11-08: a branch opened empty); until then
        # it reads as the chat it branched from, which it is.
        path, cut = transcript(sid, row), None
        if not path:
            path, cut = branch_source(rec)
        if path:
            PATHS[sid] = path
        if cut is None:
            CUT_AT.pop(sid, None)
        else:
            CUT_AT[sid] = cut
        size = cut if cut is not None else os.path.getsize(path) if path and os.path.exists(path) else 0
        held = HEADLINES.get(sid)
        if not held or held[0] != size:
            held = (size,) + headline(path, cut) if path else (0, None, None)
            HEADLINES[sid] = held
        doc = {"sid": sid, "pid": rec["pid"], "tty": tty, "name": row.get("name") or rec.get("name") or sid[:8],
               "cwd": rec.get("cwd") or row.get("cwd") or "", "branch": row.get("branch") or "",
               "vendor": vendor, "account": account, "status": rec.get("status") or "",
               "status_at": (rec.get("statusUpdatedAt") or 0) / 1000.0, "model": row.get("model") or "",
               "ctx": row.get("ctx"), "spoke": row.get("spoke") or row.get("at"), "ttl": row.get("ttl"),
               "until": row.get("until"), "warm": warm_in, "size": size, "away": held[1], "last": held[2],
               "load": per.get(sid), "pages": pages_by.get(sid, 0), "started": (rec.get("startedAt") or 0) / 1000.0,
               "procs": len(tasks(rec["pid"]))}
        if tty and rec.get("entrypoint", "cli") == "cli":
            rows.append(doc)
        else:
            workers.append(doc)
    key = lambda d: -(d.get("spoke") or d.get("started") or 0)
    found_runs = runs()
    by_session = {r["sid"]: r for r in found_runs if r.get("sid")}
    for doc in workers:
        held = by_session.get(doc["sid"])
        if held:
            held["status"] = doc["status"]
    return {"as_of": time.time(), "machine": machine, "chats": sorted(rows, key=key),
            "workers": sorted([w for w in workers if w["sid"] not in by_session], key=key),
            "runs": sorted(found_runs, key=lambda r: -r["started"]), "pins": pins(), "client": client_version()}


def pins():
    """share/chat_pins.py's pinned sessions, oldest pin first (bin/chats lifts a closed one to the top)."""
    try:
        return shared("chat_pins").pinned()
    except Exception:  # an unreadable pin file pins nothing
        return []


def client_version():
    """The client files' fingerprint (the UI kit's stylesheet with them): a running client that sees it change reloads
    itself, since nobody reloads a home-screen app by hand."""
    folder = static_dir()
    try:
        stamp = sorted((name, os.stat(os.path.join(folder, name)).st_mtime_ns) for name in os.listdir(folder))
    except OSError:
        return ""
    try:
        stamp.append(("kit/ui.css", os.stat(os.path.join(KIT, "ui.css")).st_mtime_ns))
    except OSError:
        pass
    return "%08x" % zlib.crc32(repr(stamp).encode())


# ---------------------------------------------------------------- worker runs, every vendor

RUNS = os.environ.get("WORKER_RUN_DIR") or os.path.expanduser("~/.cache/claude-worker-runs")
RUN_NAME = re.compile(r"^([a-z]+)-([0-9]{9,11})-[0-9]+-[0-9a-f]+$")
RUN_HORIZON = 2 * 86400  # launched earlier: past every cap worker-run puts on a run, so never read
PID_SLACK = 30  # share/run-liveness.sh PID_START_SLACK: a supervisor started further from its stamp is a reused pid
VENDORS = {"claudeb": "claude", "codex": "codex", "gemini": "gemini", "grok": "grok"}


def read_doc(path):
    try:
        with open(path, encoding="utf-8") as handle:
            doc = json.load(handle)
    except (OSError, ValueError):
        return {}
    return doc if isinstance(doc, dict) else {}


def first_line(path, cap=200):
    try:
        with open(path, encoding="utf-8", errors="replace") as handle:
            return handle.readline(4096).strip()[:cap]
    except OSError:
        return ""


def etime(text):
    """ps etime, [[dd-]hh:]mm:ss -> seconds, None for any other shape."""
    parts = re.split(r"[-:]", text)
    scale = {2: (60, 1), 3: (3600, 60, 1), 4: (86400, 3600, 60, 1)}.get(len(parts))
    if not scale or not all(p.isdigit() for p in parts):
        return None
    return sum(int(p) * s for p, s in zip(parts, scale))


def runs():
    """worker-run's live runs of every vendor: a run dir named with a launch epoch inside RUN_HORIZON (so the
    thousand old dirs cost one listdir), no exit_code, and its supervisor pid still running since its stamp
    (one ps for all of them)."""
    now = time.time()
    try:
        names = os.listdir(RUNS)
    except OSError:
        return []
    found = []
    for name in names:
        m = RUN_NAME.match(name)
        if not m or now - int(m.group(2)) > RUN_HORIZON:
            continue
        folder = os.path.join(RUNS, name)
        if os.path.exists(os.path.join(folder, "exit_code")):
            continue
        meta = read_doc(os.path.join(folder, "meta.json"))
        state = read_doc(os.path.join(folder, "state.json"))
        if state.get("phase") == "done" or not isinstance(meta.get("pid"), int) or meta["pid"] <= 0:
            continue
        found.append((name, folder, meta, state, int(m.group(2))))
    if not found:
        return []
    up = {}
    for line in (run(["ps", "-o", "pid=,etime=", "-p", ",".join(str(f[2]["pid"]) for f in found)]) or "").splitlines():
        parts = line.split()
        if len(parts) == 2 and parts[0].isdigit():
            up[int(parts[0])] = etime(parts[1])
    out = []
    for name, folder, meta, state, launched in found:
        elapsed, stamp = up.get(meta["pid"]), meta.get("pid_started_at")
        if meta["pid"] not in up or (elapsed is not None and isinstance(stamp, int)
                                     and abs(now - elapsed - stamp) > PID_SLACK):
            continue
        vendor = VENDORS.get(meta.get("vendor"), meta.get("vendor") or "")
        if meta.get("light"):
            vendor = VENDORS.get(meta["light"], meta["light"])
        wsid = first_line(os.path.join(folder, "worker-session"), 80)
        path = first_line(os.path.join(folder, "session-file"), 1000)
        sid = None
        if vendor == "claude" and SID_RE.match(wsid) and path.endswith(".jsonl") and os.path.isfile(path):
            sid, PATHS[wsid] = wsid, path
        tokens = first_line(os.path.join(folder, "tokens"), 20)
        out.append({"id": name, "vendor": vendor, "account": state.get("account") or meta.get("account") or "",
                    "model": state.get("model") or meta.get("model") or "",
                    "effort": state.get("effort") or meta.get("effort") or "",
                    "title": first_line(os.path.join(folder, "title")) or name,
                    "started": state.get("started_epoch") or meta.get("started_at") or launched,
                    "launcher": state.get("session") or first_line(os.path.join(folder, "launcher"), 80),
                    "phase": state.get("phase") or "", "round": state.get("round_id") or "",
                    "queued": "cli_pid" not in meta and "slot_at" in meta, "sid": sid,
                    "tokens": int(tokens) if tokens.isdigit() else None, "status": ""})
    return out


# ---------------------------------------------------------------- what went wrong, for `page report`

INCIDENTS = {}  # key -> (monotonic time of its last line, how many were swallowed since)
CLIENT_REPORTS = []  # monotonic times of the client's reports this minute
CLIENT_CAP = 20


def incident(key, **fields):
    """store.event for a repeating failure (a screen poll every 2 s): one line per key per minute, the next one
    carrying how many it swallowed."""
    if store is None:
        return
    now = time.monotonic()
    with CACHE_LOCK:
        at, swallowed = INCIDENTS.get(key, (None, 0))
        if at is not None and now - at < 60:
            INCIDENTS[key] = (at, swallowed + 1)
            return
        INCIDENTS[key] = (now, 0)
    store.event("app", **dict(fields, repeats=swallowed) if swallowed else fields)


def client_report(body):
    """POST /api/client-log: the client's own trouble (a lost connection once it is back, a script error), at most
    CLIENT_CAP lines a minute."""
    if store is None or not isinstance(body, dict):
        return
    now = time.monotonic()
    with CACHE_LOCK:
        CLIENT_REPORTS[:] = [t for t in CLIENT_REPORTS if now - t < 60]
        if len(CLIENT_REPORTS) >= CLIENT_CAP:
            return
        CLIENT_REPORTS.append(now)
    fields = {k: (v if isinstance(v, (int, float, bool)) else str(v)[:300]) for k, v in body.items()
              if k in ("kind", "msg", "path", "ms", "count", "hidden", "sid", "ua")}
    store.event("app", op="client", **fields)


def find_live(sid):
    for rec, tty, vendor, account in live():
        if rec["sessionId"] == sid:
            return rec, tty
    return None, None


# ---------------------------------------------------------------- the transcript

def clip(text, cap):
    return text if len(text) <= cap else text[:cap] + "\n… (%d more chars)" % (len(text) - cap)


def user_text(text):
    """What he typed, without the wrappers the client adds: pasted blocks unwrapped, slash commands as he typed
    them. None when the line is machinery, a dict {k, t} when it is an event rather than speech."""
    stripped = text.lstrip()
    if stripped.startswith("<task-notification>"):
        summary = re.search(r"<summary>(.*?)</summary>", stripped, re.S)
        return {"k": "event", "t": (summary.group(1) if summary else "task notification").strip()}
    if stripped.startswith(MACHINERY):
        return None
    tags = dict(TAG_RE.findall(text))
    if "command-name" in tags:
        return {"k": "user", "t": (tags["command-name"] + " " + tags.get("command-args", "")).strip()}
    if "bash-input" in tags:
        return {"k": "user", "t": "! " + tags["bash-input"]}
    if stripped.startswith(("<local-command-stdout>", "<bash-stdout>", "<local-command-stderr>", "<bash-stderr>")):
        body = "\n".join(v for k, v in tags.items() if k != "command-message").strip()
        return {"k": "event", "t": clip(body, 600)} if body else None
    text = PASTED_RE.sub(lambda m: m.group(1), text)
    return {"k": "user", "t": clip(text, TEXT_CAP)}


def tool_summary(name, args):
    if not isinstance(args, dict):
        return ""
    if isinstance(args.get("questions"), list):
        return " · ".join(q.get("question", "") for q in args["questions"] if isinstance(q, dict))[:500]
    if isinstance(args.get("todos"), list):
        return "%d todos" % len(args["todos"])
    for field in ("description", "command", "file_path", "pattern", "url", "query", "prompt", "skill", "path"):
        value = args.get(field)
        if isinstance(value, str) and value:
            if field == "description" and isinstance(args.get("command"), str):
                return value + "\n" + args["command"][:400]
            return value[:500]
    return json.dumps(args, ensure_ascii=False)[:300]


def result_text(content):
    if isinstance(content, str):
        return content
    if isinstance(content, list):
        parts = []
        for block in content:
            if isinstance(block, dict) and block.get("type") == "text":
                parts.append(block.get("text") or "")
            elif isinstance(block, dict) and block.get("type") == "image":
                parts.append("[image]")
        return "\n".join(parts)
    return ""


def parse_entry(entry):
    """One transcript line -> the app's items: user/asst speech, tool calls and their results, recaps, events."""
    kind, msg = entry.get("type"), entry.get("message") or {}
    at = entry.get("timestamp") or ""
    if entry.get("isSidechain") or msg.get("model") == "<synthetic>":
        return []
    if kind == "queue-operation":
        # What he sent while the chat was busy: queued, then absorbed mid-turn (the attachment below carries it
        # into the conversation), dequeued as the next turn, or pulled back into the Mac's input (popAll). Claude
        # Code's queue is one FIFO with its own notifications in it and a `dequeue` names no text (it takes the
        # head), so every entry is passed on and the client mirrors the queue; `hide` marks the ones not his.
        op, text = entry.get("operation"), entry.get("content")
        # What the app sends is a bracketed paste, which Claude Code wraps: his, not a notification.
        text = PASTED_RE.sub(lambda m: m.group(1), text).strip() if isinstance(text, str) else ""
        hide = not text.strip() or text.lstrip().startswith("<")
        if op == "enqueue":
            return [{"k": "queued", "t": "" if hide else clip(text, TEXT_CAP), "hide": hide, "at": at}]
        if op in ("remove", "dequeue", "popAll"):
            return [{"k": "unqueued", "t": "" if hide else clip(text, TEXT_CAP), "hide": hide, "op": op, "at": at}]
        return []
    if kind == "attachment":
        att = entry.get("attachment") if isinstance(entry.get("attachment"), dict) else {}
        origin = att.get("origin") if isinstance(att.get("origin"), dict) else {}
        if (att.get("type") == "queued_command" and att.get("commandMode") == "prompt" and not att.get("isMeta")
                and origin.get("kind", "human") == "human" and isinstance(att.get("prompt"), str)):
            item = user_text(att["prompt"])
            return [dict(item, at=att.get("timestamp") or at, mid=True)] if item else []
        return []
    if kind == "system":
        if entry.get("subtype") == "away_summary" and entry.get("content"):
            return [{"k": "away", "t": entry["content"], "at": at}]
        if entry.get("subtype") == "compact_boundary":
            return [{"k": "event", "t": "— compacted —", "at": at}]
        return []
    content = msg.get("content")
    if kind == "user":
        if entry.get("isMeta") or entry.get("isCompactSummary"):
            return []
        if isinstance(content, str):
            item = user_text(content)
            return [dict(item, at=at)] if item else []
        items, words = [], []
        for block in content if isinstance(content, list) else []:
            if not isinstance(block, dict):
                continue
            if block.get("type") == "tool_result":
                items.append({"k": "result", "id": block.get("tool_use_id"), "err": bool(block.get("is_error")),
                              "t": clip(result_text(block.get("content")), RESULT_CAP), "at": at})
            elif block.get("type") == "text" and isinstance(block.get("text"), str):
                item = user_text(block["text"])
                if item and item["k"] == "user":
                    words.append(item["t"])
            elif block.get("type") == "image":
                words.append("[image]")
        if words:
            items.insert(0, {"k": "user", "t": "\n".join(words), "at": at})
        return items
    if kind == "assistant":
        items = []
        for block in content if isinstance(content, list) else []:
            if not isinstance(block, dict):
                continue
            if block.get("type") == "text" and (block.get("text") or "").strip():
                items.append({"k": "asst", "t": clip(block["text"], TEXT_CAP), "at": at})
            elif block.get("type") == "tool_use":
                items.append({"k": "tool", "id": block.get("id"), "n": block.get("name") or "?",
                              "s": tool_summary(block.get("name"), block.get("input")), "at": at})
        return items
    return []


OLDER_SAID = 6  # the tail and an Earlier block reach back until they hold this many things said (his, Claude's) ...
OLDER_BYTES = 32 << 20  # ... or have read this much (tool output of hundreds of MB stops somewhere)
SPEECH = ("user", "asst", "away")


def said(items):
    return sum(1 for it in items if it.get("k") in SPEECH and not it.get("hide") and (it.get("t") or "").strip())


def log(sid, after=None, before=None):
    """Items of the transcript: the tail (LOG_WINDOW) with no offsets, what came after byte `after`, or the window
    that ends at byte `before`. The tail and a `before` window reach further back until they hold OLDER_SAID things
    said: what he reads is what was said, the tools between are folded (Egor 2026-11-08: a chat opened on two tool
    calls and its spinner; an Earlier block brought one or two Bash calls). -> {items, start, end}: offsets of whole
    lines, for the next call."""
    if not SID_RE.match(sid):
        return None
    path = PATHS.get(sid) or transcript(sid, cached("recent", 30, recent).get(sid))
    if not path:
        return None
    cut = CUT_AT.get(sid)
    doc = window(path, after, before, cut)
    while after is None and doc["start"] > 0 and said(doc["items"]) < OLDER_SAID and doc["end"] - doc["start"] < OLDER_BYTES:
        more = window(path, None, doc["start"], cut)
        doc = dict(doc, items=more["items"] + doc["items"], start=more["start"])
    return doc


def window(path, after, before, cut=None):
    with open(path, "rb") as handle:
        size = handle.seek(0, 2) if cut is None else cut
        if after is not None:
            start, end = min(after, size), size
        elif before is not None:
            end = min(before, size)
            start = max(0, end - LOG_WINDOW)
        else:
            end, start = size, max(0, size - LOG_WINDOW)
        handle.seek(start)
        data = handle.read(end - start)
        if start and after is None:
            cut = data.find(b"\n") + 1
            # The line before `end` is longer than the window (a pasted image, a huge result): reach back to its
            # start, or the window holds no whole line and Earlier asks for the same bytes forever.
            while start and cut >= len(data):
                step = min(start, LOG_WINDOW)
                handle.seek(start - step)
                data = handle.read(step) + data
                start -= step
                cut = data.find(b"\n") + 1 if start else 0
            start, data = start + cut, data[cut:]
    if not data.endswith(b"\n"):
        cut = data.rfind(b"\n") + 1
        end, data = start + cut, data[:cut]
    items = []
    for raw in data.splitlines():
        try:
            entry = json.loads(raw)
        except ValueError:
            continue
        if isinstance(entry, dict):
            items += parse_entry(entry)
    return {"items": items, "start": start, "end": end, "size": size, "file": os.path.basename(path)}


# ---------------------------------------------------------------- the info panel: statusline and changed files

STATUSLINE_DIR = os.environ.get("STATUSLINE_CACHE_DIR") or os.path.expanduser("~/.cache/claude-statusline")
SGR_RE = re.compile(r"\x1b\[([0-9;]*)m")
SGR = {"31": "red", "32": "green", "33": "yellow", "34": "blue", "35": "magenta", "36": "cyan", "2": "dim", "90": "dim"}
CHANGES = {}  # sid -> {path, off, used, files: {file: [added, deleted, at]}}
CHANGES_LOCK = threading.Lock()
CHANGES_STEP = 32 << 20  # transcript bytes one call reads; a longer backlog goes on at the next
CHANGES_KEEP = 200  # chats remembered; the least recently asked goes first


def status_lines(sid):
    """The chat's statusline lines 1-2 in full words (render-full-<sid>, else its fitted render-<sid>; both from
    bin/statusline.sh) -> [[[text, colour], ...], ...], colour a SGR name ('' plain)."""
    text = None
    for name in ("render-full-", "render-"):
        try:
            with open(os.path.join(STATUSLINE_DIR, name + sid), encoding="utf-8", errors="replace") as handle:
                text = handle.read(8192)
            break
        except OSError:
            continue
    out = []
    for line in (text or "").splitlines()[:2]:
        runs, colour, at = [], "", 0
        for m in SGR_RE.finditer(line + "\x1b[0m"):
            if m.start() > at:
                runs.append([line[at:m.start()], colour])
            codes = m.group(1).split(";")
            colour = "" if codes in (["0"], [""]) else next((SGR[c] for c in reversed(codes) if c in SGR), colour)
            at = m.end()
        out.append(runs)
    return out


def changes(sid, path):
    """Files this chat changed by its own Edit/Write/NotebookEdit calls that went through (their results carry
    `toolUseResult.structuredPatch`), newest first -> [{p, add, del, at}]. The transcript is read once, then only
    what it grew by."""
    with CHANGES_LOCK:
        size = os.path.getsize(path)
        st = CHANGES.get(sid)
        if st is None or st["path"] != path or size < st["off"]:
            st = CHANGES[sid] = {"path": path, "off": 0, "files": {}}
        st["used"] = time.monotonic()
        if size > st["off"]:
            with open(path, "rb") as handle:
                handle.seek(st["off"])
                data = handle.read(min(size - st["off"], CHANGES_STEP))
            cut = data.rfind(b"\n") + 1
            st["off"] += cut
            for raw in data[:cut].splitlines():
                if b'"structuredPatch"' not in raw:
                    continue
                try:
                    entry = json.loads(raw)
                    result = entry["toolUseResult"]
                    file, hunks = result["filePath"], result["structuredPatch"] or []
                except (ValueError, KeyError, TypeError):
                    continue
                if not isinstance(file, str) or not isinstance(hunks, list):
                    continue
                lines = [line for hunk in hunks if isinstance(hunk, dict) for line in hunk.get("lines") or []
                         if isinstance(line, str)]
                added = sum(line.startswith("+") for line in lines)
                deleted = sum(line.startswith("-") for line in lines)
                if result.get("type") == "create" and not hunks:
                    added = len(str(result.get("content") or "").splitlines())
                row = st["files"].setdefault(file, [0, 0, ""])
                row[0] += added
                row[1] += deleted
                row[2] = entry.get("timestamp") or row[2]
        if len(CHANGES) > CHANGES_KEEP:
            for old in sorted(CHANGES, key=lambda k: CHANGES[k]["used"])[:len(CHANGES) - CHANGES_KEEP]:
                del CHANGES[old]
        rows = sorted(st["files"].items(), key=lambda kv: kv[1][2], reverse=True)
    return [{"p": file, "add": a, "del": d, "at": at} for file, (a, d, at) in rows]


def info(sid):
    """GET /api/chat/<sid>/info -> {status, files, root}, or None without a transcript."""
    if not SID_RE.match(sid):
        return None
    row = cached("recent", 30, recent).get(sid)
    path = PATHS.get(sid) or transcript(sid, row)
    if not path:
        return None
    rec, _ = find_live(sid)
    return {"status": status_lines(sid), "files": changes(sid, path)[:80],
            "root": (rec or {}).get("cwd") or (row or {}).get("cwd") or "",
            "procs": tasks(rec["pid"], ports=True) if rec else []}


# ---------------------------------------------------------------- Terminal, through Hammerspoon

def hs(lua, timeout=6):
    """One Lua chunk in the running Hammerspoon -> its printed answer (a JSON string), or None."""
    with HS_LOCK:
        return run([HS, "-t", str(timeout - 1), "-c", lua], timeout=timeout)


def terminal(script):
    """An AppleScript through ChatGate.terminalScript -> {"ok": bool, "res": str|None, "err": str|None}."""
    lua = ("local g=package.loaded['chat_gate'] if not g then return hs.json.encode({ok=false,err='chat_gate not"
           " loaded'}) end local ok,res,d=g.terminalScript('pages-app', [==[%s]==]) return hs.json.encode({ok=ok"
           " and true or false,res=type(res)=='string' and res or nil,err=(not ok) and"
           " (type(d)=='string' and d or hs.inspect(d)) or nil})" % script)
    out = hs(lua)
    try:
        doc = json.loads(out) if out else None
    except ValueError:
        doc = None
    return doc if isinstance(doc, dict) else {"ok": False, "err": "Hammerspoon did not answer (%s)" % FAILED.get(HS)}


def in_tab(tty, body):
    """AppleScript running `body` (it returns) against the Terminal tab whose tty is `tty`; TAB in body names the tab
    and WIN its window, spelled out each time (`contents of` a variable holding the tab reads the reference, not the
    tab). Two Apple Events find it, every window's id and every tab's tty, where the loop over windows sent two per
    window, 16 ms each on Terminal's main thread (audit 2026-11-09: 65-235 ms a read by the tab's window, and
    Hammerspoon, which runs the script, held 1-5 s while Terminal was busy). The tab found is checked by its tty
    before the body runs; a lookup that fails or no longer matches falls back to the loop."""
    assert TTY_RE.match(tty)
    fast = "window id (item j of ws)"
    return ('tell application id "com.apple.Terminal"\nset ws to {}\nset ts to {}\ntry\n'
            'set ws to id of every window\nset ts to tty of every tab of every window\nend try\n'
            'if (count ws) is (count ts) then\nrepeat with j from 1 to count ws\nset row to item j of ts\n'
            'repeat with i from 1 to count row\nif item i of row is "%(tty)s" then\n'
            'if tty of tab i of %(fast)s is "%(tty)s" then\n%(quick)s\nend if\nend if\nend repeat\nend repeat\nend if\n'
            'repeat with j from 1 to count windows\n'
            'repeat with i from 1 to count tabs of window j\nif tty of tab i of window j is "%(tty)s" then\n'
            '%(slow)s\nend if\nend repeat\nend repeat\nend tell\nreturn "no-tab"'
            % {"tty": tty, "fast": fast,
               "quick": body.replace("TAB", "tab i of " + fast).replace("WIN", fast),
               "slow": body.replace("TAB", "tab i of window j").replace("WIN", "window j")})


def screen(tty):
    return cached(("screen", tty), 0.8, lambda: terminal(in_tab(tty, "return contents of TAB")))


HISTORY_CAP = 400 << 10  # chars of a tab's scrollback the Terminal sheet gets when he scrolls past the screen


def history_of(tty):
    """The tab's scrollback (Terminal's `history`), its last HISTORY_CAP chars from a line start."""
    doc = dict(cached(("history", tty), 3, lambda: terminal(in_tab(tty, "return history of TAB"))))
    text = doc.get("res") or ""
    if doc.get("ok") and len(text) > HISTORY_CAP:
        text = text[-HISTORY_CAP:]
        doc["res"] = text[text.find("\n") + 1:]
    return doc


def clears(lines):
    """AppleScript setting c to `lines` × (Ctrl+U, Backspace), which empties that many input lines. Neither key
    interrupts a working chat; Ctrl+C does even with text in the input, and so does Esc."""
    return 'set c to ""\nrepeat %d times\nset c to c & (ASCII character 21) & (ASCII character 127)\nend repeat\n' % lines


def send_text(tty, text, clear=0):
    """The text into the tab as one bracketed paste (after `clear` input lines are emptied); `do script` appends the
    Return that submits it."""
    fd, path = tempfile.mkstemp(dir=scratch(), suffix=".txt")
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as handle:
            handle.write(text)
        body = ('set txt to read POSIX file "%s" as «class utf8»\nset e to ASCII character 27\n%s'
                'do script (%se & "[200~" & txt & e & "[201~") in TAB\nreturn "sent"'
                % (path, clears(clear) if clear else "", "c & " if clear else ""))
        return terminal(in_tab(tty, body))
    finally:
        os.unlink(path)


TYPING = threading.Lock()  # one edit of a chat's input at a time: an unqueue's steps never interleave with a send
QUEUE_HINT = "Press up to edit queued"  # the empty input's placeholder while Claude Code holds queued messages
UNQUEUE_CLEAR = 40  # input lines one clearing step empties; a longer leftover takes another step


def input_box(text):
    """The prompt box's text joined by spaces ('' when empty), or None when the screen shows no prompt box."""
    lines = (text or "").splitlines()
    rules = [k for k, line in enumerate(lines) if re.match(r"^\s*─{8,}\s*$", line)]
    for low, high in zip(reversed(rules[:-1]), reversed(rules[1:])):
        if high - low < 40 and re.match(r"^\s*❯", lines[low + 1]):
            return re.sub(r"^❯\s*", "", " ".join(line.strip() for line in lines[low + 1:high])).strip()
    return None


def popped(path, offset):
    """His messages Claude Code's popAll put into the input after byte `offset` of the transcript, in order."""
    try:
        with open(path, "rb") as handle:
            handle.seek(offset)
            data = handle.read(1 << 20)
    except OSError:
        return []
    out = []
    for line in data.splitlines():
        try:
            entry = json.loads(line)
        except ValueError:
            continue
        text = entry.get("content") if isinstance(entry, dict) else None
        if (entry.get("type") == "queue-operation" and entry.get("operation") == "popAll" and isinstance(text, str)
                and text.strip() and not text.lstrip().startswith("<")):
            out.append(text)
    return out


def unqueue(tty, path, text):
    """One of his queued messages taken back before the chat reads it -> {ok} or {ok: False, err, back: [texts the
    Mac's input lost]}. `do script` ends every write with a Return, so first Up pulls Claude Code's whole queue into
    the empty input, Ctrl+U/Backspace empty it and a closing backslash turns that Return into a new line: nothing is
    ever submitted. The transcript's popAll lines then say what came out (Up with the queue already taken recalls
    history: no popAll, and that is only cleared), and every message but this one goes back, in order, each queued
    again by its own paste + Return."""
    look = lambda: input_box((terminal(in_tab(tty, "return contents of TAB")) or {}).get("res"))
    box = look()
    if box is None or not box.startswith(QUEUE_HINT):
        return {"ok": False, "err": "no prompt on the Mac's screen" if box is None
                else "the Mac's input is not empty" if box else "nothing queued on the Mac"}
    offset = os.path.getsize(path)
    step = terminal(in_tab(tty, clears(UNQUEUE_CLEAR) + 'set e to ASCII character 27\n'
                           'do script (e & "[A" & c & "\\\\") in TAB\nreturn "sent"'))
    if not step.get("ok"):
        return step
    for _ in range(4):
        time.sleep(0.3)
        box = look()
        if box is not None and not box.replace("\\", "").strip():
            break
        terminal(in_tab(tty, clears(UNQUEUE_CLEAR) + 'do script (c & "\\\\") in TAB\nreturn "sent"'))
    else:
        return {"ok": False, "err": "the Mac's input did not clear", "back": popped(path, offset)}
    out = popped(path, offset)
    for _ in range(5):
        if out:
            break
        time.sleep(0.2)
        out = popped(path, offset)
    want = " ".join(text.split())
    kept = list(out)
    hit = next((k for k, item in enumerate(kept) if " ".join(item.split()) == want), None)
    if hit is not None:
        del kept[hit]
    for k, item in enumerate(kept):
        sent = send_text(tty, item, clear=4 if k == 0 else 0)
        if not sent.get("ok"):
            return {"ok": False, "err": sent.get("err") or "Terminal did not take it back", "back": kept[k:]}
    if not kept:
        terminal(in_tab(tty, clears(4) + 'do script c in TAB\nreturn "sent"'))  # the line the backslash left
    return {"ok": True} if hit is not None else {"ok": False, "err": "it had already gone to the chat"}


def menu_cursor(text):
    """The number of the menu option the ❯ cursor is on, from the bottom of the screen, or None."""
    for line in reversed((text or "").splitlines()[-40:]):
        m = re.match(r"^\s*[│ ]*\s*❯\s*(\d+)\.", line)
        if m:
            return int(m.group(1))
    return None


def send_key(tty, key, choose=None):
    """esc / enter / up / down, or choose=N: arrows from the ❯ option to N; `do script` appends the Enter."""
    seq = {"esc": '(ASCII character 27)', "enter": '""', "up": '(e & "[A")', "down": '(e & "[B")'}.get(key)
    if choose is not None:
        current = menu_cursor((screen(tty) or {}).get("res"))
        if current is None:
            return {"ok": False, "err": "no menu on the screen"}
        step = '(e & "[B")' if choose > current else '(e & "[A")'
        seq = " & ".join([step] * abs(choose - current)) or '""'
        with CACHE_LOCK:
            CACHE.pop(("screen", tty), None)
    if seq is None:
        return {"ok": False, "err": "unknown key"}
    return terminal(in_tab(tty, 'set e to ASCII character 27\ndo script %s in TAB\nreturn "sent"' % seq))


# ---------------------------------------------------------------- the menubar mirror

# ---------------------------------------------------------------- past chats: the list, a search, open, close

HISTORY_TTL = 3  # s


def history_doc(seen=""):
    """{chats, h}: h the list's hash; {same, h} when the client already holds that list."""
    rows = history()
    h = "%08x" % zlib.crc32(json.dumps(rows, sort_keys=True).encode())
    return {"same": True, "h": h} if seen == h else {"chats": rows, "h": h}


def history():
    """chat-find --recent, newest real message first: every chat he can go back to (live ones too; the client marks
    them), with what it last said, and `until` while its prompt cache is warm (Egor 2026-11-09: Earlier shows the
    cache's minutes as a live chat does); a pinned chat older than its window comes in too, as `chats` lists it."""
    rows = []
    # chat-find answers from its own cache in a tenth of a second: a closed chat is in Earlier within seconds.
    found = dict(cached("recent", HISTORY_TTL, recent))
    gone = tuple(p for p in pins() if p not in found)
    if gone:
        found.update(cached(("pinned", gone), HISTORY_TTL, lambda: recent(gone)))
    label = shared("chat_names").project_label
    now = time.time()
    for r in found.values():
        held = dict(r)
        until = held.get("until") if warm(held) and (held.get("until") or 0) > now else None
        rows.append({"sid": r["session"], "name": r.get("name") or "", "cwd": r.get("cwd") or "", "until": until,
                     "project": label(r.get("cwd") or ""),
                     "branch": r.get("branch") or "", "model": r.get("model") or "",
                     "spoke": r.get("spoke") or r.get("at"), "role": r.get("role") or "",
                     "text": (r.get("text") or "")[:240]})
    return sorted(rows, key=lambda r: -(r["spoke"] or 0))


TEMP_DIRS = ("/tmp/", "/private/tmp/")


def projects():
    """The folders a new chat can start in: every one a chat ran in that is still there, a worktree's as its main
    checkout, temp ones left out; the latest first, with how many chats it holds."""
    names = shared("chat_names")
    folders = {}
    for r in cached("recent", HISTORY_TTL, recent).values():
        cwd = r.get("cwd") or ""
        cut = cwd.find(names.WORKTREES)
        cwd = (cwd[:cut] if cut > 0 else cwd).rstrip("/")
        if not cwd.startswith("/") or (cwd + "/").startswith(TEMP_DIRS):
            continue
        f = folders.setdefault(cwd, {"cwd": cwd, "name": names.project_label(cwd), "spoke": 0, "n": 0})
        f["n"] += 1
        f["spoke"] = max(f["spoke"], r.get("spoke") or r.get("at") or 0)
    return sorted((f for f in folders.values() if os.path.isdir(f["cwd"])), key=lambda f: -f["spoke"])


def search(q):
    """chat-find <words> --json: the chats where he said it, newest first (it reads every transcript: seconds)."""
    terms = q.split()[:8]
    if not terms:
        return []
    finder = os.environ.get("APP_CHAT_FIND") or os.path.join(repo(), "bin", "chat-find")
    out = run([sys.executable, finder, "--json", "--limit", "40", "--"] + terms, timeout=90)
    try:
        rows = json.loads(out) if out else None
    except ValueError:
        rows = None
    if not isinstance(rows, list):
        return None
    return [{"sid": r.get("session"), "name": r.get("name") or "", "cwd": r.get("cwd") or "", "spoke": r.get("at"),
             "title": (r.get("title") or "")[:240], "text": (r.get("snippet") or "")[:240]}
            for r in rows if isinstance(r, dict) and r.get("session")]


def open_chat(sid, fork=None, account=None):
    """A past chat into a new Terminal window, as `chats` opens it (its account: the live cache, else the best one;
    `account` one he picked). A chat already open is not opened twice (a second resume forks it): the app just shows
    it. fork (a name, or ""): a branch of it in a new window, open or not, under that name (claude --fork-session)."""
    rec, _ = find_live(sid)
    if rec and fork is None:
        return 200, {"ok": True, "live": True}
    # One typed in a moment ago and not up yet (a message sent while Open waits) is not resumed a second time.
    if fork is None and time.time() - OPENED.get(sid, 0) < OPEN_WAIT:
        return 200, {"ok": True, "pending": True}
    line, meta = chats_line("--open-command", sid, *(["--account", account] if account else []))
    if line is None:
        return 502, {"ok": False, "err": meta}
    if fork is not None:
        line += " --fork-session" + (" --name=" + shlex.quote(fork) if fork else "")  # = : a name may start with -
    code, doc = in_window(line, meta)
    if doc.get("ok") and fork is None:
        OPENED[sid] = time.time()
    return code, doc


OPEN_WAIT = float(os.environ.get("APP_OPEN_WAIT") or 60)  # s for a chat opened by a message to come up
OPENED = {}  # sid -> when this server typed its resume into a window
ACCOUNT_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$")


def open_and_send(sid, text):
    """A message to a closed chat (Egor 2026-11-09: it did not go, and opening was a separate step): the chat opens
    as Open in Terminal opens it, on its default account, and once it runs and waits for him (idle twice, a second
    apart) the message goes in as any send."""
    code, doc = open_chat(sid)
    if not doc.get("ok"):
        return code, doc
    end, idle = time.time() + OPEN_WAIT, 0
    while time.time() < end:
        rec, tty = find_live(sid)
        idle = idle + 1 if rec and tty and rec.get("status") == "idle" else 0
        if idle >= 2:
            with TYPING:
                answer = send_text(tty, text)
            if answer.get("res") == "no-tab":
                answer = {"ok": False, "err": "no Terminal tab on %s" % tty}
            return (200 if answer.get("ok") else 502), dict(answer, opened=doc.get("account", "") or True)
        time.sleep(1)
    return 504, {"ok": False, "err": "it opened%s but did not come up in %d s" % (
        " as " + doc["account"] if doc.get("account") else "", OPEN_WAIT)}


def chat_accounts(sid):
    """`chats --accounts SID` -> (code, {accounts, gateway}): what Open in Terminal offers."""
    picker = os.environ.get("APP_CHATS") or os.path.join(repo(), "bin", "chats")
    out = run([sys.executable, picker, "--accounts", sid, "--timeout", "8"], timeout=40)
    try:
        doc = json.loads(out) if out else None
    except ValueError:
        doc = None
    if not isinstance(doc, dict) or not isinstance(doc.get("accounts"), list):
        return 502, {"ok": False, "err": re.sub(r"^exit \d+: ", "", FAILED.get(sys.executable) or "chats printed nothing")}
    return 200, dict(doc, ok=True)


def chats_line(*args):
    """`chats --open-command SID` / `--new-command DIR`: (the command line, {account, source}), or (None, why)."""
    picker = os.environ.get("APP_CHATS") or os.path.join(repo(), "bin", "chats")
    out = run([sys.executable, picker] + list(args) + ["--timeout", "8"], timeout=40)
    lines = (out or "").splitlines()
    if not lines or not lines[0].strip():
        why = (FAILED.get(sys.executable) if out is None else None) or "chats printed nothing"
        return None, re.sub(r"^exit \d+: ", "", why)
    meta = dict(word.split("=", 1) for word in (lines[1] if len(lines) > 1 else "").split() if "=" in word)
    return lines[0].strip(), meta


def in_window(line, meta):
    """A `chats` command line typed into a new Terminal window -> (code, doc with the account it picked); the new
    tab is watched for the folder-trust question (trust_watch)."""
    literal = line.replace("\\", "\\\\").replace('"', '\\"')
    doc = terminal('tell application id "com.apple.Terminal"\nset t to do script "%s"\nend tell\n'
                   'tell application id "com.apple.Terminal" to return tty of t' % literal)
    if not doc.get("ok"):
        return 502, {"ok": False, "err": doc.get("err") or "Terminal did not open it"}
    tty = doc.get("res") or ""
    if TTY_RE.match(tty):
        threading.Thread(target=trust_watch, args=(tty,), daemon=True).start()
    return 200, {"ok": True, "account": meta.get("account", ""), "source": meta.get("source", "")}


TRUST_WAIT = float(os.environ.get("APP_TRUST_WAIT") or 40)  # s a chat this app opened is watched for the question


def trust_watch(tty):
    """Claude Code asks whether to trust a folder before a chat starts, and in the home folder every time (it never
    keeps that answer there): a chat opened from this app stopped on it, unseen (Egor 2026-11-09, 'Open in Terminal'
    waited and showed nothing). In the tab this app just opened, with the cursor on "No, exit" over "Yes, I trust
    this folder", it is answered yes (he opened his own chat, or a new one in a folder of his chats); anything else
    on that screen is left alone. The watch ends once a chat runs on that tab, or after TRUST_WAIT."""
    end = time.time() + TRUST_WAIT
    while time.time() < end:
        time.sleep(0.8)
        if any(t == tty for _, t, _, _ in live()):
            return
        with CACHE_LOCK:
            CACHE.pop(("screen", tty), None)
        text = (screen(tty) or {}).get("res") or ""
        if "Yes, I trust this folder" in text and re.search(r"❯\s*No, exit", text):
            with TYPING:
                answer = send_key(tty, "down")  # do script adds the Return: Down, then Enter on "Yes"
            if store is not None:
                store.event("app", op="trust", tty=tty, error=None if answer.get("ok") else str(answer.get("err"))[:300])
            return


def new_chat(cwd):
    """A new chat in a folder he picked, in a new Terminal window: `chats --new-command` (worker-pick's account for
    a chat, the default model)."""
    if not isinstance(cwd, str) or not cwd.startswith("/") or not os.path.isdir(cwd):
        return 400, {"ok": False, "err": "no such folder"}
    line, meta = chats_line("--new-command", cwd)
    return (502, {"ok": False, "err": meta}) if line is None else in_window(line, meta)


CLOSE_WAIT = float(os.environ.get("APP_CLOSE_WAIT") or 8)  # s for an /exit to end the chat; then the window stays


# ---------------------------------------------------------------- what a chat runs: its processes

# Claude Code's own children, not his work: the sleep guard of a working turn and its event helpers.
OWN_KID = re.compile(r"^(\S*/)?caffeinate\s|/\.claude[^/\s]*/hooks/|/claude-setup/hooks/")
EVAL_RE = re.compile(r"&& eval '((?:[^']|'\\'')*)'")
INTERPRETERS = {"python", "python3", "node", "ruby", "perl", "bash", "sh", "zsh", "bun", "deno"}


def ptree():
    """Every process, one ps: ({pid: (ppid, seconds up, cpu %, rss KB, command)}, {ppid: [pid]})."""
    out = run(["ps", "-A", "-ww", "-o", "pid=,ppid=,etime=,%cpu=,rss=,command="], env=dict(os.environ, LC_ALL="C")) or ""
    procs, kids = {}, {}
    for line in out.splitlines():
        parts = line.split(None, 5)
        if len(parts) < 6 or not parts[0].isdigit() or not parts[1].isdigit():
            continue
        try:
            up = etime_seconds(parts[2])
            pid, ppid, cpu, rss = int(parts[0]), int(parts[1]), float(parts[3]), int(parts[4])
        except ValueError:
            continue
        procs[pid] = (ppid, up, cpu, rss, parts[5])
        kids.setdefault(ppid, []).append(pid)
    return procs, kids


def etime_seconds(text):
    """ps's elapsed time, [[dd-]hh:]mm:ss -> seconds."""
    days, _, clock = text.rpartition("-")
    total = 0
    for part in clock.split(":"):
        total = total * 60 + int(part)
    return total + (int(days) * 86400 if days else 0)


def subtree(kids, pid):
    out, todo = [], [pid]
    while todo:
        p = todo.pop()
        out.append(p)
        todo.extend(kids.get(p, ()))
    return out


def short_command(cmd):
    """A process's command as he would have typed it: the Bash tool's shell wrapper gone (its eval'd line), an
    interpreter running a script shown as the script, paths under his home as ~."""
    m = EVAL_RE.search(cmd)
    if m:
        cmd = m.group(1).replace("'\\''", "'")
    cmd = re.sub(r"^cd \S+ && ", "", cmd.strip())
    words = cmd.split(" ")
    if words and words[0].startswith("/"):
        words[0] = os.path.basename(words[0])
    if words and words[0].lower().rstrip("0123456789.") in INTERPRETERS:
        words[0] = words[0].lower()
        if len(words) > 1 and words[1].startswith(("/", "~")):
            words = [os.path.basename(words[1])] + words[2:]
    return " ".join(words).replace(os.path.expanduser("~") + "/", "~/")[:300]


def tasks(pid, ports=False, fresh=False):
    """What a live chat runs: its children (the Bash tool's shells, background servers, monitors) minus Claude Code's
    own, each with its subtree summed -> [{pid, cmd, up, cpu, mem, n, ports?}], longest running first."""
    if fresh:
        with CACHE_LOCK:
            CACHE.pop("ptree", None)
    procs, kids = cached("ptree", 2.5, ptree)
    out = []
    for kid in kids.get(pid, ()):
        cmd = procs[kid][4]
        if OWN_KID.search(cmd):
            continue
        tree = subtree(kids, kid)
        out.append({"pid": kid, "cmd": short_command(cmd), "up": procs[kid][1], "tree": tree,
                    "cpu": round(sum(procs[p][2] for p in tree if p in procs), 1),
                    "mem": round(sum(procs[p][3] for p in tree if p in procs) / 1024.0), "n": len(tree)})
    if ports and out:
        heard = listening(sorted(p for t in out for p in t["tree"]))
        for t in out:
            t["ports"] = sorted({port for p in t["tree"] for port in heard.get(p, ())})
    for t in out:
        del t["tree"]
    return sorted(out, key=lambda t: -t["up"])


def listening(pids):
    """pid -> the TCP ports it listens on (one lsof for the chat's processes, cached 5 s)."""
    def look():
        out = run(["lsof", "-nP", "-a", "-iTCP", "-sTCP:LISTEN", "-p", ",".join(map(str, pids)), "-Fpn"], timeout=5) or ""
        found, pid = {}, None
        for line in out.splitlines():
            if line.startswith("p") and line[1:].isdigit():
                pid = int(line[1:])
            elif line.startswith("n") and pid is not None:
                port = line.rpartition(":")[2]
                if port.isdigit():
                    found.setdefault(pid, set()).add(int(port))
        return found
    return cached(("ports", tuple(pids)), 5, look)


def stop_tree(root, kids=None):
    """A process and everything under it: TERM, then KILL what is still there after 3 s -> how many there were."""
    if kids is None:
        kids = cached("ptree", 0, ptree)[1]
    victims = subtree(kids, root)
    for sig in (signal.SIGTERM, signal.SIGKILL):
        for p in victims:
            try:
                os.kill(p, sig)
            except OSError:
                pass
        deadline = time.monotonic() + 3
        while sig == signal.SIGTERM and time.monotonic() < deadline and any(alive(p) for p in victims):
            time.sleep(0.1)
        victims = [p for p in victims if alive(p)]
        if not victims:
            break
    with CACHE_LOCK:
        CACHE.pop("ptree", None)
        CACHE.pop("chats", None)
    return len(subtree(kids, root))


def alive(pid):
    try:
        os.kill(pid, 0)
        return True
    except ProcessLookupError:
        return False
    except OSError:
        return True


def stop_task(sid, pid):
    """One of a live chat's processes (its tree) stopped: only one its tasks list shows."""
    rec, _ = find_live(sid)
    if not rec:
        return 404, {"ok": False, "err": "not a live chat"}
    if not isinstance(pid, int) or pid not in [t["pid"] for t in tasks(rec["pid"], fresh=True)]:
        return 404, {"ok": False, "err": "not a process of this chat (it ended?)"}
    return 200, {"ok": True, "stopped": stop_tree(pid)}


def close_chat(sid, force=False):
    """An idle live chat ends (/exit, as typed) and its Terminal window closes; a window with other tabs stays.
    A working one, or one holding processes (background servers: status shell), only when forced (Egor
    2026-11-08: warn, he agrees, it ends): its turn interrupted (Esc), its processes stopped, then /exit."""
    rec, tty = find_live(sid)
    if not tty or rec.get("entrypoint", "cli") != "cli":
        return 404, {"ok": False, "err": "not a live terminal chat"}
    held = tasks(rec["pid"], fresh=True)
    if (rec.get("status") in ("busy", "shell") or held) and not force:
        return 409, {"ok": False, "err": "it is working: stop it first", "status": rec.get("status"), "procs": len(held)}
    if force and rec.get("status") == "busy":
        send_key(tty, "esc")
        deadline = time.monotonic() + 5
        while time.monotonic() < deadline:
            time.sleep(0.4)
            with CACHE_LOCK:
                CACHE.pop("live", None)
            now_rec, _ = find_live(sid)
            if not now_rec or now_rec.get("status") != "busy":
                break
    if force:
        for t in tasks(rec["pid"], fresh=True):
            stop_tree(t["pid"])
    with TYPING:
        sent = send_text(tty, "/exit", clear=2)
    if not sent.get("ok") or sent.get("res") == "no-tab":
        return 502, {"ok": False, "err": sent.get("err") or "no Terminal tab on %s" % tty}
    deadline = time.monotonic() + CLOSE_WAIT
    while time.monotonic() < deadline:
        try:
            os.kill(rec["pid"], 0)
        except ProcessLookupError:
            break
        except OSError:
            pass
        time.sleep(0.2)
    else:
        return 504, {"ok": False, "err": "the chat did not exit (a question on its screen?)"}
    with CACHE_LOCK:
        CACHE.pop("live", None)
        CACHE.pop("chats", None)
    doc = terminal(in_tab(tty, 'if (count tabs of WIN) is 1 then\nclose WIN\nreturn "closed"\n'
                                'end if\nreturn "tabs"'))
    res = doc.get("res")
    return 200, {"ok": True, "window": res if doc.get("ok") and res in ("closed", "tabs") else "left"}


TRASH = os.environ.get("APP_TRASH") or os.path.expanduser("~/.local/bin/trash")
NAME_CAP = 100


def chat_title(body):
    """The name a rename or a branch asked for, on one line -> str ("" for none), None when malformed."""
    name = body.get("name", "") if isinstance(body, dict) else None
    if not isinstance(name, str):
        return None
    return " ".join(name.split())[:NAME_CAP]


def forget_lists():
    with CACHE_LOCK:
        for key in [k for k in CACHE if k in ("recent", "chats", "live") or (isinstance(k, tuple) and k[0] == "pinned")]:
            CACHE.pop(key, None)


def rename_chat(sid, name):
    """A live terminal chat gets `/rename <name>` typed (Claude Code records it and titles its window); a closed one
    gets the line /rename writes, a custom-title event at the end of its transcript, which every name reader and the
    next resume take."""
    rec, tty = find_live(sid)
    if rec:
        if not tty or rec.get("entrypoint", "cli") != "cli":
            return 409, {"ok": False, "err": "not a terminal chat"}
        # Its Return would answer a question on the screen or queue the command behind a turn.
        if rec.get("status") == "busy" or menu_cursor((screen(tty) or {}).get("res")) is not None:
            return 409, {"ok": False, "err": "it is working or asking: rename it once it waits for you"}
        with TYPING:
            sent = send_text(tty, "/rename " + name, clear=2)
        if not sent.get("ok") or sent.get("res") == "no-tab":
            return 502, {"ok": False, "err": sent.get("err") or "no Terminal tab on %s" % tty}
    else:
        path = PATHS.get(sid) or transcript(sid, cached("recent", HISTORY_TTL, recent).get(sid))
        if not path or not os.path.isfile(path):
            return 404, {"ok": False, "err": "no transcript"}
        with open(path, "rb") as handle:
            handle.seek(max(0, os.path.getsize(path) - 1))
            torn = handle.read(1) not in (b"", b"\n")
        line = json.dumps({"type": "custom-title", "customTitle": name, "sessionId": sid}, ensure_ascii=False)
        with open(path, "a", encoding="utf-8") as handle:
            handle.write(("\n" if torn else "") + line + "\n")
    forget_lists()
    return 200, {"ok": True, "live": bool(rec)}


def trash_chat(sid, force=False):
    """The chat into the trash /trash uses (claude-setup's session-trash.sh: out of every history, restorable).
    A live one is marked and ended (/exit, its window closed; a working one only forced, as close): its session end
    moves it; a closed one is marked and swept at once."""
    rec, tty = find_live(sid)
    if rec and (not tty or rec.get("entrypoint", "cli") != "cli"):
        return 409, {"ok": False, "err": "not a terminal chat"}
    held = tasks(rec["pid"], fresh=True) if rec and not force else []
    if rec and not force and (rec.get("status") in ("busy", "shell") or held):
        return 409, {"ok": False, "err": "it is working: stop it first", "status": rec.get("status"), "procs": len(held)}
    path = None if rec else PATHS.get(sid) or transcript(sid, cached("recent", HISTORY_TTL, recent).get(sid))
    if not rec and not path:
        return 404, {"ok": False, "err": "no transcript"}
    FAILED.pop(TRASH, None)
    if "marked" not in (run([TRASH, "mark", sid], timeout=10) or ""):
        return 502, {"ok": False, "err": "trash: %s" % (FAILED.get(TRASH) or "it did not mark the chat")}
    window = None
    if rec:
        code, doc = close_chat(sid, force)
        if not doc.get("ok"):
            run([TRASH, "unmark", sid], timeout=10)
            return code, doc
        window = doc.get("window")
    else:
        root = os.path.dirname(os.path.dirname(os.path.dirname(path)))
        out = run([TRASH, "sweep"], timeout=60, env=dict(os.environ, CLAUDE_CONFIG_DIR=root))
        if ("trashed %s" % sid) not in (out or ""):
            run([TRASH, "unmark", sid], timeout=10)
            return 502, {"ok": False, "err": "trash: %s" % (FAILED.get(TRASH) or "it did not take the chat")}
    if sid in pins():
        shared("chat_pins").pin(sid, False)
    forget_lists()
    return 200, {"ok": True, "live": bool(rec), "window": window}


def untrash_chat(sid):
    """A trashed chat back where it was (session-trash.sh restore). One its end has not moved yet (a live chat's
    session end purges it 2 s later) only loses its mark, which that purge then skips."""
    FAILED.pop(TRASH, None)
    out = run([TRASH, "restore", sid], timeout=30)
    if ("restored %s" % sid) not in (out or "") and ("unmarked %s" % sid) not in (run([TRASH, "unmark", sid], timeout=10) or ""):
        return 502, {"ok": False, "err": "trash: %s" % (FAILED.get(TRASH) or "nothing to restore")}
    forget_lists()
    return 200, {"ok": True}


MENU_LUA = r"""
local m = package.loaded['llm-limits']
if not m or not m.menuItems then return hs.json.encode({err='llm-limits not loaded'}) end
local function hex(c)
  if type(c) ~= 'table' then return nil end
  local r, g, b = c.red, c.green, c.blue
  if r == nil and c.white ~= nil then r, g, b = c.white, c.white, c.white end
  if r == nil then return nil end
  return string.format('%02x%02x%02x', math.floor(r*255+0.5), math.floor(g*255+0.5), math.floor(b*255+0.5)),
    c.alpha or 1
end
local function runs(title)
  if type(title) == 'string' then return {{t=title}} end
  if type(title) ~= 'userdata' then return {{t=tostring(title or '')}} end
  local ok, tb = pcall(function() return title:asTable() end)
  if not ok or type(tb) ~= 'table' then return {{t=title:getString()}} end
  local s, out, at = tb[1] or '', {}, 1
  for i = 2, #tb do
    local r = tb[i]
    if type(r) == 'table' and r.starts then
      -- asTable's starts lands on the LAST byte of a multibyte first character (ends is right): step back
      -- to its lead byte, and keep any byte no run covers as plain text.
      local first = r.starts
      while first > at and first > 1 and (s:byte(first) or 0) >= 0x80 and (s:byte(first) or 0) < 0xC0 do
        first = first - 1
      end
      if first > at then out[#out+1] = {t=s:sub(at, first - 1)} end
      at = math.max(at, r.ends + 1)
      local a = r.attributes or {}
      local seg = {t=s:sub(first, r.ends)}
      local c, al = hex(a.color)
      if c then seg.c = c; seg.a = al end
      if a.font and type(a.font.name) == 'string' and a.font.name:find('Bold') then seg.b = true end
      out[#out+1] = seg
    end
  end
  if at <= #s then out[#out+1] = {t=s:sub(at)} end
  return out
end
local function conv(items, depth)
  local out = {}
  for _, it in ipairs(items or {}) do
    if it.title == '-' then out[#out+1] = {sep=true}
    else
      local e = {r=runs(it.title)}
      if it.checked then e.ck = true end
      if it.disabled then e.dis = true end
      if type(it.menu) == 'table' and depth < 4 then e.sub = conv(it.menu, depth+1) end
      out[#out+1] = e
    end
  end
  return out
end
local ok, items = pcall(m.menuItems)
if not ok then return hs.json.encode({err=tostring(items)}) end
return hs.json.encode({items=conv(items, 1)})
"""


def menu():
    def make():
        out = hs(MENU_LUA)
        try:
            doc = json.loads(out) if out else None
        except ValueError:
            doc = None
        return doc if isinstance(doc, dict) else {"err": "Hammerspoon did not answer (%s)" % FAILED.get(HS)}
    return cached("menu", 4, make)


# ---------------------------------------------------------------- pages

def pages():
    out = []
    for pid in store.all_pages():
        m = store.meta(pid)
        out.append({"pid": pid, "title": m.get("title") or pid, "chat": m.get("chat_name") or "",
                    "owner": m.get("owner") or "", "module": m.get("module") or "",
                    "updated": m.get("updated") or "", "created": m.get("created") or ""})
    return sorted(out, key=lambda p: p["updated"], reverse=True)


# ---------------------------------------------------------------- the microphone, through transcriptions-gpt

daemon = None  # set by bin/page: one control line to transcriptions-gpt (verb, request=None) -> its reply or None
MIC_PORT = int(os.environ.get("APP_MIC_PORT") or 47654)  # the daemon's iPad receiver (its ipad-mic/PROTOCOL.md)
MIC_FRAME = 640  # 20 ms of 16 kHz mono int16, one audio packet
MIC_CHUNK_CAP = 256 << 10
MIC_PAD_AFTER = 0.4  # s without audio before silence frames keep the take under the daemon's 1.5 s stall limit
MIC_IDLE_LIMIT = 45  # s without a chunk or beat: the client is gone and its take is cancelled (no cap on a live take's
# length: a 15-minute one threw away a quarter hour of his dictation). A page iPadOS suspends a while (another app in
# front, MacMic opened) keeps its take: silence pads the gap (Egor 2026-11-08: 10 s dropped a take mid-dictation)
MIC_WAIT = 120  # s from stop to the transcript
# MacMic (transcriptions-gpt ipad-mic/, a native iPad app) streams the iPad microphone to the daemon: the fallback once
# the browser was refused the microphone (WebKit bug 329593 in the Home Screen app: NotAllowedError, no prompt,
# through reloads). A take via MacMic keeps it streaming this long; a look at the pill does not (Egor 2026-11-09: the
# browser first, he leaves MacMic).
MACMIC_WANT = 2 * 3600
MACMIC_WAKE_WAIT = 12  # s for MacMic's stream after the daemon launched it in the background (6 s on 2026-11-08)
MICS = {}
MIC_LOCK = threading.Lock()


class Mic:
    """One remote take: the browser's PCM relayed to the receiver as audio packets (its own streamID), padded with
    silence between HTTP bursts; the daemon writes the transcript to `path` instead of pasting it."""

    def __init__(self, relay=True, mic_id=None):
        self.relay = relay  # False: MacMic's stream is the take, nothing of ours goes to the receiver
        self.id = mic_id or os.urandom(8).hex()
        self.stream = int.from_bytes(os.urandom(4), "big")
        self.seq = 0
        self.rest = b""
        self.sent_at = self.chunk_at = time.monotonic()
        self.lock = threading.Lock()
        self.done = threading.Event()
        self.stopping = False
        self.sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        self.path = os.path.join(scratch(), "mic-%s.txt" % self.id)
        threading.Thread(target=self.pad, daemon=True).start()

    def frames(self, pcm):
        """Whole frames of rest + pcm go out now; a torn tail waits for the next chunk. Under self.lock."""
        data = self.rest + pcm
        whole = len(data) - len(data) % MIC_FRAME
        for at in range(0, whole, MIC_FRAME):
            packet = b"TGMA" + self.stream.to_bytes(4, "big") + self.seq.to_bytes(4, "big") + data[at:at + MIC_FRAME]
            try:
                self.sock.sendto(packet, ("127.0.0.1", MIC_PORT))
            except OSError:
                pass  # the receiver fills a lost frame with silence
            self.seq = (self.seq + 1) & 0xFFFFFFFF
        self.rest = data[whole:]
        self.sent_at = time.monotonic()

    def chunk(self, pcm):
        with self.lock:
            self.chunk_at = time.monotonic()
            self.frames(pcm)

    def pad(self):
        while not self.done.wait(0.1):
            now = time.monotonic()
            with self.lock:
                if self.relay and now - self.sent_at > MIC_PAD_AFTER:
                    self.frames(bytes(MIC_FRAME * 5))
            if not self.stopping and now - self.chunk_at > MIC_IDLE_LIMIT:
                cancel_take("idle-cancel")
                self.close()

    def close(self):
        self.done.set()
        with MIC_LOCK:
            if MICS.get(self.id) is self:
                del MICS[self.id]
        try:
            self.sock.close()
        except OSError:
            pass
        for name in (self.path, self.path + ".part"):
            try:
                os.unlink(name)
            except OSError:
                pass


def scratch():
    folder = os.path.join(tempfile.gettempdir(), "pages-app")
    os.makedirs(folder, mode=0o700, exist_ok=True)
    return folder


def daemon_state():
    answer = daemon("status")
    return answer.split()[0] if answer else None


def cancel_take(why="cancel"):
    """The daemon's take of ours ends unsaid -> the state it settled in (within 3 s). The daemon's cancel is its Esc:
    on an idle daemon it would hit the newest other track (a transform)."""
    before = daemon_state()
    if before not in ("recording", "processing"):
        return before
    answer = daemon("cancel")
    deadline, state = time.monotonic() + 3, before
    while time.monotonic() < deadline:
        state = daemon_state()
        if state != before:
            break
        time.sleep(0.1)
    if store is not None:
        store.event("app", op="mic", path=why, error=None if state != before else
                    "cancel (%s) left the daemon %s" % (answer, state))
    return state


def our_orphan():
    """The daemon records a remote take while no page has one open here: ours, its page and its end lost."""
    try:
        doc = json.loads(daemon("bubble") or "")
    except ValueError:
        return False
    with MIC_LOCK:
        open_here = bool(MICS)
    return isinstance(doc, dict) and doc.get("remote") is True and doc.get("state") == "recording" and not open_here


def macmic_fields():
    """The daemon's `ipad-mic` line -> its fields, {} with no daemon or receiver."""
    answer = daemon("ipad-mic") if daemon else None
    if not answer or not answer.startswith("ok "):
        return {}
    return {k: v.strip('"') for k, v in re.findall(r'(\w+)=("(?:[^"\\]|\\.)*"|\S+)', answer[3:])}


def macmic_state(fields=None):
    """MacMic -> "streaming" (the receiver hears a peer that is not this Mac, whose packets are our own relay),
    "asleep", or "" with no daemon or receiver."""
    fields = macmic_fields() if fields is None else fields
    if not fields:
        return ""
    local = fields.get("peer", "None") in ("None", "127.0.0.1", "::1", "::ffff:127.0.0.1")
    return "streaming" if fields.get("present") == "True" and not local else "asleep"


def macmic_wake():
    """MacMic streaming, woken first (the daemon's `ipad-wake`: a launch in the background on the iPad) when asleep,
    suspended or not running -> True once it streams."""
    if macmic_state() == "streaming":
        return True
    daemon("ipad-want %d" % MACMIC_WANT)
    if not (daemon("ipad-wake") or "").startswith("ok"):
        return False
    deadline = time.monotonic() + MACMIC_WAKE_WAIT
    while time.monotonic() < deadline:
        time.sleep(0.3)
        fields = macmic_fields()
        if macmic_state(fields) == "streaming":
            return True
        if fields.get("wake") == "failed":
            return False
    return False


def mic_start(body=None):
    """A take on the Mac's transcriptions-gpt fed from this browser, or with {"via": "macmic"} recording MacMic's
    stream -> {ok, id, via} once it records."""
    if daemon is None or daemon_state() is None:
        return 503, {"ok": False, "err": "transcriptions-gpt is not running"}
    relay = not (isinstance(body, dict) and body.get("via") == "macmic")
    if not relay and not macmic_wake():
        return 409, {"ok": False, "err": "MacMic did not wake: open it on the iPad"}
    # A new start is his only take: one still open lost its page (a reload, a cancel that never arrived) and would
    # refuse him for MIC_IDLE_LIMIT seconds. One being transcribed is kept, its text is on the way.
    with MIC_LOCK:
        stale = [m for m in MICS.values() if not m.stopping]
    for old in stale:
        old.stopping = True
        cancel_take()
        old.close()
    with MIC_LOCK:
        if MICS:
            return 409, {"ok": False, "err": "the last dictation is still being transcribed"}
        mic = Mic(relay)
        MICS[mic.id] = mic
    if relay:
        with mic.lock:
            mic.frames(bytes(MIC_FRAME * 5))  # the receiver must see the stream before remote-start
    answer = daemon("remote-start", {"deliver": mic.path})
    if answer == "ignored recording" and our_orphan_after(mic):
        # A take of ours that outlived its page (its cancel lost): his new tap ends it and starts.
        answer = daemon("remote-start", {"deliver": mic.path})
    if answer != "ok":
        mic.close()
        return 409, {"ok": False, "err": "transcriptions-gpt: %s" % (answer or "no answer")}
    deadline = time.monotonic() + 4
    while time.monotonic() < deadline:
        if daemon_state() == "recording":
            # The capture attaches right after the state flips; the client's first chunk may not beat it.
            time.sleep(0.25)
            return 200, {"ok": True, "id": mic.id, "via": "browser" if relay else "macmic"}
        time.sleep(0.05)
    cancel_take()
    mic.close()
    return 504, {"ok": False, "err": "transcriptions-gpt did not start recording"}


def adopt(mic_id, verb):
    """A take this server lost (a restart empties MICS) while the daemon still records it into scratch()/mic-<id>.txt,
    no page holding one here: the page's next chunk, beat or stop takes it up again under its id, so what was said is
    not lost (Egor 2026-11-09: 285 s into a take its chunks got 404 with the daemon still recording; only a restore
    of the cancelled take brought the text back) -> the Mic, or None."""
    if verb == "cancel" or not our_orphan():
        return None
    with MIC_LOCK:
        if MICS:
            return MICS.get(mic_id)
        mic = MICS[mic_id] = Mic(relay=verb == "chunk", mic_id=mic_id)
    if store is not None:
        store.event("app", op="mic", path="adopt", error="a take this server had lost, taken up again at its %s" % verb)
    return mic


def our_orphan_after(mic):
    with MIC_LOCK:
        MICS.pop(mic.id, None)
    try:
        return our_orphan() and cancel_take("orphan-cancel") == "idle"
    finally:
        with MIC_LOCK:
            MICS[mic.id] = mic


def mic_stop(mic):
    """The take ends; the daemon transcribes it and writes the text -> {ok, text}."""
    mic.stopping = True
    daemon("stop")
    deadline, idle_at = time.monotonic() + MIC_WAIT, None
    try:
        while time.monotonic() < deadline:
            if os.path.exists(mic.path):
                with open(mic.path, encoding="utf-8") as handle:
                    return 200, {"ok": True, "text": handle.read()}
            state = daemon_state()
            # One stop only: a second one reaching an idle daemon would start a take on the Mac.
            if state in ("idle", None):
                idle_at = idle_at or time.monotonic()
                if time.monotonic() - idle_at > 2:
                    return 200, {"ok": False, "err": "nothing was transcribed"}
            time.sleep(0.15)
        return 504, {"ok": False, "err": "no transcript in %d s" % MIC_WAIT}
    finally:
        mic.close()


MIC_RESTORE_WAIT = 240  # s: a restore transcribes the whole cut take again


def mic_bubble():
    """What the Mac's voice pill shows and offers now (transcriptions-gpt `bubble`, its ipad-mic/PROTOCOL.md "Remote
    take"): he works from the iPad and never sees that pill -> {ok, state, pill, polish_since, alt, degraded, restore}."""
    answer = daemon("bubble") if daemon else None
    try:
        doc = json.loads(answer or "")
    except ValueError:
        doc = None
    if not isinstance(doc, dict):
        return 200, {"ok": False, "err": "transcriptions-gpt has no bubble" if answer else "transcriptions-gpt is not running"}
    return 200, dict(doc, ok=True, macmic=macmic_state())


def mic_usealt():
    """The pill's click on a ready other result, or the polish seconds' paste-now; a take of ours gets that text."""
    answer = daemon("usealt") if daemon else None
    return 200, {"ok": answer == "ok", "err": "" if answer == "ok" else answer or "transcriptions-gpt is not running"}


def mic_webreset():
    """The iPad's web view restarted (transcriptions-gpt's ipad-webreset ends SafariViewService): WebKit refuses a Home
    Screen web app the microphone, no prompt, for that process's life once the app opened a new window (WebKit bug
    329593); a swipe-away does not end it. The app closes; reopened, it asks for the microphone anew."""
    answer = daemon("ipad-webreset") if daemon else None
    ok = bool(answer) and answer.startswith("ok")
    return (200 if ok else 503), {"ok": ok, "err": "" if ok else answer or "transcriptions-gpt is not running"}


def mic_restore(body):
    """A cut take back as text for the draft: transcriptions-gpt restores the named, else the offered, else the newest
    cancelled take into a file instead of pasting on the Mac; a take of ours still recording is discarded by it."""
    if daemon is None or daemon_state() is None:
        return 503, {"ok": False, "err": "transcriptions-gpt is not running"}
    with MIC_LOCK:
        ours = list(MICS.values())
    if any(m.stopping for m in ours):
        return 409, {"ok": False, "err": "the last dictation is still being transcribed"}
    path = os.path.join(scratch(), "restore-%s.txt" % os.urandom(8).hex())
    request = {"deliver": path}
    name = body.get("name") if isinstance(body, dict) else None
    if isinstance(name, str) and name:
        request["name"] = name
    for m in ours:
        m.stopping = True  # its idle cancel must not hit the restore
    answer = daemon("restore", request)
    if answer != "ok":
        for m in ours:
            m.stopping = False
        return 409, {"ok": False, "err": "transcriptions-gpt: %s" % (answer or "no answer")}
    for m in ours:
        m.close()
    deadline, idle_at = time.monotonic() + MIC_RESTORE_WAIT, None
    try:
        while time.monotonic() < deadline:
            if os.path.exists(path):
                with open(path, encoding="utf-8") as handle:
                    return 200, {"ok": True, "text": handle.read()}
            # The daemon's main loop takes the restore up a moment later: idle only counts once it has had time.
            if daemon_state() in ("idle", None):
                idle_at = idle_at or time.monotonic()
                if time.monotonic() - idle_at > 6:
                    return 200, {"ok": False, "err": "nothing was restored"}
            else:
                idle_at = None
            time.sleep(0.2)
        return 504, {"ok": False, "err": "no restored text in %d s" % MIC_RESTORE_WAIT}
    finally:
        for name in (path, path + ".part"):
            try:
                os.unlink(name)
            except OSError:
                pass


def mic_post(path, body):
    """POST /api/mic/(start|usealt|restore|webreset) | /api/mic/<id>/(chunk|alive|stop|cancel) -> (code, doc), or None when
    not a mic route."""
    if path == "/api/mic/start":
        return mic_start(body)
    if path == "/api/mic/usealt":
        return mic_usealt()
    if path == "/api/mic/restore":
        return mic_restore(body)
    if path == "/api/mic/webreset":
        return mic_webreset()
    m = re.fullmatch(r"/api/mic/([0-9a-f]{16})/(chunk|alive|stop|cancel)", path)
    if not m:
        return None
    with MIC_LOCK:
        mic = MICS.get(m.group(1))
    if mic is None:
        mic = adopt(m.group(1), m.group(2))
    if mic is None:
        return 404, {"ok": False, "err": "that dictation is over"}
    if m.group(2) == "chunk":
        mic.chunk(body)
        return 200, {"ok": True}
    if m.group(2) == "alive":  # a MacMic take's client is still there (it sends no audio); level draws its wave
        mic.chunk_at = time.monotonic()
        fields = macmic_fields()
        try:
            level = float(fields.get("level", 0))
        except ValueError:
            level = 0.0
        return 200, {"ok": True, "level": level, "macmic": macmic_state(fields)}
    if m.group(2) == "stop":
        return mic_stop(mic)
    mic.stopping = True
    cancel_take()
    mic.close()
    return 200, {"ok": True}


# ---------------------------------------------------------------- HTTP

TYPES = {".html": "text/html; charset=utf-8", ".js": "text/javascript; charset=utf-8",
         ".css": "text/css; charset=utf-8", ".png": "image/png", ".svg": "image/svg+xml"}


def get(handler, path, query):
    """GET /app/... and /api/...; True when handled."""
    if path in ("/app", "/app/"):
        path = "/app/index.html"
    if path == "/app/manifest.webmanifest":
        token = getattr(handler.server, "lan_token", None)
        start = "/app/?k=%s" % token if token else "/app/"
        doc = {"name": "Mac chats", "short_name": "Chats", "start_url": start, "scope": "/",
               "display": "standalone", "background_color": "#1c1c1e", "theme_color": "#1c1c1e",
               "icons": [{"src": "/app/icon.png", "sizes": "512x512", "type": "image/png"}]}
        handler.reply(200, json.dumps(doc).encode(), "application/manifest+json", [("Cache-Control", "no-cache")])
        return True
    if path.startswith("/app/"):
        name = path[5:]
        if not re.fullmatch(r"[a-z0-9-]+\.(html|js|css|png|svg)", name):
            handler.reply(404, b"not found\n")
            return True
        full = os.path.join(static_dir(), name)
        try:
            with open(full, "rb") as fh:
                filestat = os.fstat(fh.fileno())
                tag = '"%x-%x"' % (filestat.st_mtime_ns, filestat.st_size)
                # An unchanged file is revalidated, not sent again (166 KB per load on the iPad's Wi-Fi)
                same = handler.headers.get("If-None-Match") == tag
                body = b"" if same else fh.read()
        except OSError:
            handler.reply(404, b"not found\n")
            return True
        headers = [("Cache-Control", "no-cache"), ("ETag", tag)]
        handler.reply(304 if same else 200, body, TYPES[os.path.splitext(name)[1]], headers)
        return True
    if path == "/api/chats":
        handler.send_json(200, cached("chats", 2.5, chats))
        return True
    if path == "/api/menu":
        handler.send_json(200, menu())
        return True
    if path == "/api/mic/bubble":
        handler.send_json(*mic_bubble())
        return True
    if path == "/api/load":
        try:
            with open(CHATS_JSON, encoding="utf-8") as handle:
                doc = json.load(handle)
        except (OSError, ValueError):
            doc = {}
        handler.send_json(200, {"title": doc.get("title") or "", "rows": doc.get("rows") or [], "as_of": doc.get("as_of")})
        return True
    if path == "/api/pages":
        handler.send_json(200, {"pages": pages()})
        return True
    if path == "/api/history":
        handler.send_json(200, history_doc((query.get("h") or [""])[0]))
        return True
    if path == "/api/projects":
        handler.send_json(200, {"projects": projects()})
        return True
    if path == "/api/search":
        q = " ".join((query.get("q") or [""])[0].split())[:200]
        found = cached(("search", q), 120, lambda: search(q))
        if found is None:
            with CACHE_LOCK:
                CACHE.pop(("search", q), None)
            handler.send_json(502, {"err": "chat-find failed: %s" % FAILED.get(sys.executable, "?")})
        else:
            handler.send_json(200, {"chats": found})
        return True
    m = re.fullmatch(r"/api/chat/([A-Za-z0-9-]+)/(log|screen|info|procs|accounts)", path)
    if m:
        sid, sub = m.groups()
        if sub == "accounts":
            code, doc = chat_accounts(sid) if SID_RE.match(sid) else (400, {"ok": False, "err": "bad session id"})
            handler.send_json(code, doc)
            return True
        if sub == "procs":
            rec, _ = find_live(sid)
            handler.send_json(200 if rec else 404, {"procs": tasks(rec["pid"], ports=True, fresh=True)} if rec
                              else {"err": "not a live chat"})
            return True
        if sub == "info":
            doc = info(sid)
            handler.send_json(200 if doc else 404, doc or {"err": "no transcript"})
            return True
        if sub == "log":
            number = lambda k: int(query[k][0]) if query.get(k, [""])[0].isdigit() else None
            doc = log(sid, number("after"), number("before"))
            if doc is None:
                handler.send_json(404, {"err": "no transcript"})
            else:
                doc["pages"] = [{"pid": p, "title": store.meta(p).get("title") or p} for p in store.owner_pages(sid)]
                handler.send_json(200, doc)
            return True
        rec, tty = find_live(sid)
        if not tty:
            handler.send_json(404, {"err": "not a live terminal chat"})
            return True
        started = time.monotonic()
        doc = history_of(tty) if query.get("history") else screen(tty)
        if not doc.get("ok") or doc.get("res") == "no-tab":
            incident(("screen", sid), op="screen", sid=sid, error=str(doc.get("err") or doc.get("res"))[:300],
                     ms=int((time.monotonic() - started) * 1000))
        handler.send_json(200, doc)
        return True
    return False


def post(handler, path, body):
    """POST /api/chat/<sid>/(send|key|unqueue|open|close|pin|rename|branch|trash|untrash|stop), /api/new and /api/mic/...; True when handled. body is the parsed JSON object (a mic
    chunk's raw PCM bytes)."""
    if path == "/api/client-log":
        client_report(body)
        handler.send_json(200, {"ok": True})
        return True
    if path.startswith("/api/mic/"):
        answer = mic_post(path, body)
        if answer is None:
            return False
        if store is not None and not answer[1].get("ok"):
            store.event("app", op="mic", path=path[9:20], error=str(answer[1].get("err"))[:300])
        handler.send_json(*answer)
        return True
    if path == "/api/new":
        code, doc = new_chat(body.get("cwd") if isinstance(body, dict) else None)
        if store is not None and not doc.get("ok"):
            store.event("app", op="new", error=str(doc.get("err"))[:300])
        handler.send_json(code, doc)
        return True
    m = re.fullmatch(r"/api/chat/([A-Za-z0-9-]+)/(send|key|unqueue|open|close|pin|rename|branch|trash|untrash|stop)", path)
    if not m:
        return False
    sid, sub = m.groups()
    if sub == "pin":
        if not SID_RE.match(sid):
            handler.send_json(400, {"ok": False, "err": "bad session id"})
            return True
        on = body.get("on", True) if isinstance(body, dict) else True
        handler.send_json(200, {"ok": True, "pins": shared("chat_pins").pin(sid, bool(on))})
        with CACHE_LOCK:
            CACHE.pop("chats", None)
        return True
    if sub == "stop":
        pid = body.get("pid") if isinstance(body, dict) else None
        code, doc = stop_task(sid, pid) if SID_RE.match(sid) else (400, {"ok": False, "err": "bad session id"})
        if store is not None:
            store.event("app", op="stop", sid=sid, pid=pid, error=None if doc.get("ok") else str(doc.get("err"))[:300])
        handler.send_json(code, doc)
        return True
    if sub in ("open", "close", "rename", "branch", "trash", "untrash"):
        if not SID_RE.match(sid):
            handler.send_json(400, {"ok": False, "err": "bad session id"})
            return True
        name = chat_title(body) if sub in ("rename", "branch") else ""
        if name is None or (sub == "rename" and not name):
            handler.send_json(400, {"ok": False, "err": "a name, on one line"})
            return True
        force = isinstance(body, dict) and body.get("force") is True
        account = body.get("account") if isinstance(body, dict) else None
        if account is not None and not (isinstance(account, str) and ACCOUNT_RE.match(account)):
            handler.send_json(400, {"ok": False, "err": "bad account"})
            return True
        code, doc = {"open": lambda: open_chat(sid, account=account), "close": lambda: close_chat(sid, force),
                     "rename": lambda: rename_chat(sid, name), "branch": lambda: open_chat(sid, fork=name),
                     "trash": lambda: trash_chat(sid, force), "untrash": lambda: untrash_chat(sid)}[sub]()
        if store is not None and not doc.get("ok"):
            store.event("app", op=sub, sid=sid, error=str(doc.get("err"))[:300])
        handler.send_json(code, doc)
        return True
    rec, tty = find_live(sid)
    if sub == "send" and not rec and isinstance(body, dict) and body.get("open") is True and SID_RE.match(sid):
        text = body.get("text")
        if not isinstance(text, str) or not text.strip() or len(text.encode()) > SEND_CAP:
            handler.send_json(400, {"ok": False, "err": "empty or too long"})
            return True
        code, doc = open_and_send(sid, text)
        if store is not None and not doc.get("ok"):
            store.event("app", op="send-open", sid=sid, error=str(doc.get("err"))[:300])
        handler.send_json(code, doc)
        return True
    if not tty or rec.get("entrypoint", "cli") != "cli":
        handler.send_json(404, {"ok": False, "err": "not a live terminal chat"})
        return True
    if sub in ("send", "unqueue"):
        text = body.get("text") if isinstance(body, dict) else None
        if not isinstance(text, str) or not text.strip() or len(text.encode()) > SEND_CAP:
            handler.send_json(400, {"ok": False, "err": "empty or too long"})
            return True
        path = sub == "unqueue" and (PATHS.get(sid) or transcript(sid, cached("recent", 30, recent).get(sid)))
        if sub == "unqueue" and not path:
            handler.send_json(404, {"ok": False, "err": "no transcript"})
            return True
        with TYPING:
            answer = send_text(tty, text) if sub == "send" else unqueue(tty, path, text)
    else:
        key = body.get("key") if isinstance(body, dict) else None
        choose = body.get("choose") if isinstance(body, dict) else None
        if choose is not None and not (isinstance(choose, int) and 0 < choose < 30):
            handler.send_json(400, {"ok": False, "err": "bad choice"})
            return True
        with TYPING:
            answer = send_key(tty, key, choose)
    if answer.get("res") == "no-tab":
        answer = {"ok": False, "err": "no Terminal tab on %s" % tty}
    with CACHE_LOCK:
        CACHE.pop(("screen", tty), None)
    if store is not None and not answer.get("ok"):
        store.event("app", op=sub, sid=sid, error=str(answer.get("err"))[:300])
    handler.send_json(200 if answer.get("ok") else 502, answer)
    return True
