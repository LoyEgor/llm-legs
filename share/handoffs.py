"""Open handoffs of the sweep repositories: `docs/handoffs/*.md` whose first `Status:` line reads open.
Each becomes a night job (`bin/night-run carry`); the LLM doctor's debt row names one open past STALE_S.
A handoff addressed (its To/For paragraph) to a chat («name») that is live right now is that chat's, never a night job.
`owner_batches` groups them by owner chat for `night-run carry`: an owner with a decision section, two or more
handoffs or one naming a git repository outside the night's (`--outside <file>` prints those; the night cannot land
there), its chat found by exact name among `chat-find --recent`. A handoff's owner, first that applies:
1. its first To/For addressee («name», or a known chat name opening a `To:` text) that is a known chat;
2. evidence on the repository files the handoff names (backticked or plain paths existing in a sweep repo,
   `docs/handoffs/` aside): per file basename, each chat's Edit/Write/MultiEdit uses plus the basename's mentions
   in its own messages and tool inputs (never tool output), as its share of all chats' evidence on that basename;
   the top sum of shares wins. Transcripts modified in the last NIGHT_RUN_OWNER_DAYS (60) days are read, a
   subagent's or worker's counting for the chat that ran it. The batch is `doubt` with a `runner_up` when the
   top has under twice the runner-up's score or the ledger owner differs;
3. the ledger owner: the doctor ledger row naming the file (`owners.<block>`, else `owner`);
4. none: the handoff stays a night job.
`python3 share/handoffs.py [--batches]` prints handoffs, or those batches, as JSON lines."""
import datetime
import glob
import json
import os
import re
import subprocess
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

STALE_S = 60 * 3600
HEAD_LINES = 20
STATUS_RE = re.compile(r"^\**Status:?\**\s*(.*)", re.I)
NAME_RE = re.compile(r"«([^»]+)»")
ADDRESS_RE = re.compile(r"^\**(To|For|TO|FOR)\b(?!\s+[\w-]+,)")
DECIDE_RE = re.compile(r"^#+\s.*(yours to decide|decision)", re.I | re.M)
NAMED_RE = re.compile(r"handoffs/([A-Za-z0-9_.-]+?\.md)")
PATH_RE = re.compile(r"(?<![\w/.~-])/?[\w.-]+(?:/[\w.-]+)+|(?<=`)[\w.-]+\.[A-Za-z]+(?=`)")
EDIT_RE = rb'"name":"(?:Edit|Write|MultiEdit)","input":\{(?:"[a-z_]+":(?:true|false|null|-?\d+),)*"file_path":"(?P<file>(?:[^"\\]|\\.)*)"'
OWNER_DAYS = 60
TYPE_RE = rb'"type":"(?:assistant|user|tool_result|attachment|progress)"'
SPOKEN = {b'"type":"assistant"', b'"type":"user"'}
TO_RE = re.compile(r"\bTo:\s*«?([^«»(]+)")
EVIDENCE_CACHE_VERSION = 2
SCAN_CHUNK = 400


def repo_list(path):
    try:
        with open(path) as handle:
            return [line.strip() for line in handle if line.strip()]
    except OSError:
        return []


def sweep_repos():
    return repo_list(os.environ.get("NIGHT_RUN_SWEEP_REPOS") or os.path.expanduser("~/.claude/sweep-repos"))


def helper_repos():
    """The harness's helper repositories (share/night-helper-repos): night-fixable, never swept."""
    path = os.environ.get("NIGHT_RUN_HELPER_REPOS")
    if path is None:
        # a faked sweep list means a test: the real helpers would get its night refs
        path = os.devnull if os.environ.get("NIGHT_RUN_SWEEP_REPOS") else os.path.join(
            os.path.dirname(os.path.abspath(__file__)), "night-helper-repos")
    return repo_list(path)


def written_at(path):
    found = re.match(r"(\d{4}-\d{2}-\d{2})-", os.path.basename(path))
    if found:
        try:
            return time.mktime(datetime.datetime.strptime(found.group(1), "%Y-%m-%d").timetuple())
        except ValueError:
            pass
    try:
        return os.path.getmtime(path)
    except OSError:
        return None


def head(path):
    try:
        with open(path, encoding="utf-8", errors="replace") as handle:
            return [handle.readline() for _ in range(HEAD_LINES)]
    except OSError:
        return []


def addressees(lines):
    names, inside = {}, False
    for line in lines:
        inside = bool(ADDRESS_RE.match(line)) or inside and bool(line.strip())
        if inside:
            names.update(dict.fromkeys(n.strip() for n in NAME_RE.findall(line)))
    return list(names)


def live_chats():
    import chat_names
    names = set()
    for path in chat_names.session_store_files():
        try:
            with open(path) as handle:
                record = json.load(handle)
            os.kill(int(record["pid"]), 0)
        except (OSError, ValueError, KeyError, TypeError):
            continue
        name = chat_names.chat_name(str(record.get("sessionId") or ""))
        if name:
            names.add(name.strip().lower())
    return names


def open_handoffs(repos=None, now=None, live=None):
    now = time.time() if now is None else now
    out = []
    for repo in sweep_repos() if repos is None else repos:
        for path in sorted(glob.glob(os.path.join(repo, "docs", "handoffs", "*.md"))):
            lines = head(path)
            status = next((m.group(1) for m in map(STATUS_RE.match, lines) if m), "")
            if not status.lower().startswith("open"):
                continue
            to = addressees(lines)
            at = written_at(path)
            out.append({"repo": repo, "path": path, "rel": os.path.relpath(path, repo),
                        "slug": os.path.basename(path)[:-3], "at": at,
                        "age_s": None if at is None else int(now - at), "to": to})
    if out and any(h["to"] for h in out):
        names = live_chats() if live is None else {n.lower() for n in live}
        for handoff in out:
            handoff["live"] = [n for n in handoff["to"] if n.lower() in names]
    for handoff in out:
        handoff.setdefault("live", [])
    return out


def strings(value):
    if isinstance(value, str):
        yield value
    elif isinstance(value, dict):
        for item in value.values():
            yield from strings(item)
    elif isinstance(value, list):
        for item in value:
            yield from strings(item)


def ledger_owners(repos):
    named = {}
    for repo in repos:
        for path in sorted(glob.glob(os.path.join(repo, "share", "*-ledger.json"))):
            try:
                with open(path) as handle:
                    ledger = json.load(handle)
            except (OSError, ValueError):
                continue
            for row in ledger.get("rows") or []:
                owner = (ledger.get("owners") or {}).get(row.get("block")) or ledger.get("owner")
                if not owner:
                    continue
                for name in {n for text in strings(row) for n in NAMED_RE.findall(text)}:
                    counts = named.setdefault(name, {})
                    counts[owner] = counts.get(owner, 0) + 1
    return named


def recent_chats():
    try:
        out = subprocess.run(["chat-find", "--recent", "--json"], capture_output=True, text=True, timeout=120).stdout
        return json.loads(out or "[]")
    except (OSError, ValueError, subprocess.SubprocessError):
        return []


def decides(path):
    try:
        with open(path, encoding="utf-8", errors="replace") as handle:
            return bool(DECIDE_RE.search(handle.read()))
    except OSError:
        return False


def slugify(name, fallback):
    return re.sub(r"[^a-z0-9]+", "-", name.lower()).strip("-") or fallback[:8]


def named_files(path, repos):
    try:
        with open(path, encoding="utf-8", errors="replace") as handle:
            text = handle.read()
    except OSError:
        return set()
    found = set()
    for token in PATH_RE.findall(text):
        token = token.rstrip(".")
        for repo in repos:
            rel = token[len(repo) + 1:] if token.startswith(repo + os.sep) else token.lstrip(os.sep)
            if not rel.startswith("docs/handoffs/") and os.path.isfile(os.path.join(repo, rel)):
                found.add(os.path.join(repo, rel))
    return found


def outside_repos(path, repos):
    import chat_names
    try:
        with open(path, encoding="utf-8", errors="replace") as handle:
            text = handle.read()
    except OSError:
        return []
    night = {os.path.realpath(repo) for repo in list(repos) + helper_repos()}
    found = []
    for token in PATH_RE.findall(text):
        if not token.startswith(os.sep):
            continue
        top = token.rstrip(".")
        cut = top.find(chat_names.WORKTREES)
        top = top[:cut] if cut > 0 else top
        while top != os.sep and not os.path.exists(os.path.join(top, ".git")):
            top = os.path.dirname(top)
        top = os.path.realpath(top)
        if top != os.sep and top not in night and top not in found:
            found.append(top)
    return found


def in_repo(path, repos):
    import chat_names
    cut = path.find(chat_names.WORKTREES)
    if cut > 0:
        rest = path[cut + len(chat_names.WORKTREES):].split(os.sep, 1)
        path = os.path.join(path[:cut], rest[1]) if len(rest) == 2 else path[:cut]
    return path if any(path.startswith(repo + os.sep) for repo in repos) else None


def transcripts(horizon):
    import chat_names
    out, roots = {}, []
    for root in chat_names.transcript_roots():
        real = os.path.realpath(root)
        if real not in roots:
            roots.append(real)
    for root in roots:
        for path in glob.glob(os.path.join(root, "*", "*.jsonl")) + glob.glob(os.path.join(root, "*", "*", "subagents", "*.jsonl")):
            try:
                info = os.stat(path)
            except OSError:
                continue
            if info.st_mtime >= horizon:
                parts = path.split(os.sep)
                session = parts[-1][:-6] if parts[-2] != "subagents" else parts[-3]
                out[path] = (session, "%d:%r" % (info.st_size, info.st_mtime))
    return out


def scan(paths, names):
    import chat_names
    found = {path: {"edits": {}, "mentions": {}} for path in paths}
    words = "|".join(n.replace(".", r"\.") for n in sorted(names, key=lambda n: (-len(n), n)))
    # rg's engine has no lookbehind, so the left boundary is matched and lies outside the group; an
    # escaped \n or \t in the JSON is a boundary too.
    expr = "(?P<edit>%s)|(?P<type>%s)%s" % (EDIT_RE.decode(), TYPE_RE.decode(),
                                          r"|(?:^|\\[nrt]|[^\w.\\-])(?P<name>%s)" % words if words else "")
    pattern = re.compile(expr.encode())
    argv, exe = chat_names.searcher()

    def tally(path, hits):
        types = {hit.group("type") for hit in hits if hit.group("type")}
        if not types or not types <= SPOKEN:
            return
        row = found[path]
        for hit in hits:
            if hit.group("edit"):
                count(row["edits"], json.loads(b'"' + hit.group("file") + b'"'))
            elif hit.group("name"):
                count(row["mentions"], hit.group("name").decode())

    if argv[0] == "rg":
        for at in range(0, len(paths), SCAN_CHUNK):
            chunk = paths[at:at + SCAN_CHUNK]
            run = subprocess.run(["rg", "-o", "-n", "--null", "--with-filename", "--no-heading", "--no-messages",
                                  "-e", expr, "--"] + chunk, executable=exe, capture_output=True)
            if run.returncode not in (0, 1):
                unread = [path for path in chunk if not os.access(path, os.R_OK)]
                for path in unread or chunk:
                    found.pop(path, None)
                if not unread:
                    continue
            line, hits = None, []
            for raw in run.stdout.splitlines() + [b"\0:"]:
                path, _, rest = raw.partition(b"\0")
                number, _, text = rest.partition(b":")
                if (path, number) != line:
                    if hits:
                        tally(line[0].decode("utf-8", "replace"), hits)
                    line, hits = (path, number), []
                hit = pattern.fullmatch(text)
                if hit:
                    hits.append(hit)
        return found
    for path in paths:
        try:
            with open(path, "rb") as handle:
                for line in handle:
                    tally(path, list(pattern.finditer(line)))
        except OSError:
            pass
    return found


def count(counts, key):
    counts[key] = counts.get(key, 0) + 1


def evidence_cache_path():
    return os.environ.get("NIGHT_RUN_OWNER_CACHE") or os.path.expanduser("~/.cache/night-run/owner-evidence.json")


def transcript_evidence(horizon, names):
    listed, names = transcripts(horizon), sorted(names)
    try:
        with open(evidence_cache_path()) as handle:
            cache = json.load(handle)
        rows = cache["rows"] if cache.get("version") == EVIDENCE_CACHE_VERSION else {}
    except (OSError, ValueError, KeyError, TypeError, AttributeError):
        rows = {}
    stale = [path for path, (_, key) in listed.items()
             if (rows.get(path) or {}).get("key") != key or not set(names) <= set(rows[path].get("names") or [])]
    if stale:
        for path, row in scan(stale, names).items():
            rows[path] = dict(row, key=listed[path][1], names=names)
        rows = {path: row for path, row in rows.items() if path in listed}
        target = evidence_cache_path()
        tmp = "%s.tmp.%d" % (target, os.getpid())
        try:
            os.makedirs(os.path.dirname(target), exist_ok=True)
            with open(tmp, "w") as handle:
                json.dump({"version": EVIDENCE_CACHE_VERSION, "rows": rows}, handle)
            os.replace(tmp, target)
        except OSError:
            pass
    return {path: (listed[path][0], rows[path]) for path in listed if path in rows}


def evidence_scores(targets, evidence, names, repos):
    import chat_names
    launchers, per_base = chat_names.worker_run_launchers(), {}
    for session, row in evidence.values():
        chat = names.get(chat_names.fold_session(session, launchers))
        if not chat:
            continue
        hits = {os.path.basename(t): row["mentions"].get(os.path.basename(t), 0) for t in targets}
        for path, uses in row["edits"].items():
            if in_repo(path, repos) in targets:
                hits[os.path.basename(path)] += uses
        for base, n in hits.items():
            if n:
                per_base.setdefault(base, {})
                per_base[base][chat] = per_base[base].get(chat, 0) + n
    scores = {}
    for chats in per_base.values():
        total = sum(chats.values())
        for chat, n in chats.items():
            scores[chat] = scores.get(chat, 0) + n / total
    return {chat: round(score, 2) for chat, score in scores.items()}


def addressed(handoff, known):
    named = next((n for n in handoff["to"] if n in known), None)
    if named:
        return named
    lowered = {n.lower(): n for n in known}
    for text in (m.group(1).strip().lower() for line in head(handoff["path"]) for m in TO_RE.finditer(line)):
        fits = [n for n in lowered if text.startswith(n)]
        if fits:
            return lowered[max(fits, key=len)]
    return None


def pick_owner(to, ledger, scores):
    if to:
        return {"owner": to, "by": "to", "doubt": False, "runner_up": None, "scores": {}}
    ranked = sorted(scores, key=lambda n: (-scores[n], n))
    if ranked:
        top = ranked[0]
        close = len(ranked) > 1 and scores[top] < 2 * scores[ranked[1]]
        rival = ranked[1] if close else ledger if ledger and ledger != top else None
        return {"owner": top, "by": "edits", "doubt": rival is not None, "runner_up": rival, "scores": scores}
    if ledger:
        return {"owner": ledger, "by": "ledger", "doubt": False, "runner_up": None, "scores": {}}
    return None


def owner_picks(handoffs, repos, chats, always=False):
    named = ledger_owners(repos)
    known = {c["name"] for c in chats if c.get("name") and c.get("session")}
    sessions = {}
    for chat in chats:
        if chat.get("name") and chat.get("session"):
            sessions.setdefault(chat["session"], chat["name"])
    wanted = []
    for handoff in handoffs:
        to = addressed(handoff, known)
        roots = repos + [handoff["repo"]] * (handoff["repo"] not in repos)
        targets = set() if to and not always else {in_repo(t, repos) or t for t in named_files(handoff["path"], roots)}
        wanted.append((handoff, to, targets))
    names = {os.path.basename(t) for _, _, targets in wanted for t in targets}
    if names:
        days = float(os.environ.get("NIGHT_RUN_OWNER_DAYS") or OWNER_DAYS)
        evidence = transcript_evidence(time.time() - days * 86400, names)
    picks = []
    for handoff, to, targets in wanted:
        counts = named.get(os.path.basename(handoff["path"]), {})
        ledger = max(counts, key=lambda o: counts[o]) if counts else None
        scores = evidence_scores(targets, evidence, sessions, repos) if targets else {}
        picks.append((handoff, ledger, pick_owner(to, ledger, scores), scores))
    return picks


def owner_batches(handoffs, repos=None, chats=None, live=None):
    if not handoffs:
        return []
    repos = sweep_repos() if repos is None else repos
    chats = recent_chats() if chats is None else chats
    groups = {}
    for handoff, ledger, pick, _ in owner_picks(handoffs, repos, chats):
        if pick:
            groups.setdefault(pick["owner"], []).append(dict(handoff, pick=pick, ledger=ledger))
    groups = {o: hs for o, hs in groups.items()
              if len(hs) >= 2 or any(decides(h["path"]) or outside_repos(h["path"], repos) for h in hs)}
    if not groups:
        return []
    names = live_chats() if live is None else {n.lower() for n in live}
    out = []
    for owner, batch in groups.items():
        chat = next((c for c in chats if c.get("name") == owner and c.get("session")), None)
        if chat is None:
            continue
        scores = {}
        for handoff in batch:
            for name, hits in handoff["pick"]["scores"].items():
                scores[name] = scores.get(name, 0) + hits
        rivals = sorted({h["pick"]["runner_up"] for h in batch if h["pick"]["doubt"]}, key=lambda n: (-scores.get(n, 0), n))
        out.append({"owner": owner, "slug": slugify(owner, chat["session"]), "session": chat["session"],
                    "cwd": chat.get("cwd") or "", "live": owner.lower() in names,
                    "by": sorted({h["pick"]["by"] for h in batch}), "doubt": bool(rivals),
                    "runner_up": rivals[0] if rivals else None,
                    "scores": {n: round(scores.get(n, 0), 2) for n in [owner] + rivals[:1]} if rivals else {},
                    "at": min((h["at"] for h in batch if h["at"] is not None), default=None),
                    "handoffs": [h["path"] for h in batch], "repos": sorted({h["repo"] for h in batch})})
    return sorted(out, key=lambda b: (b["at"] is None, b["at"] or 0, b["owner"]))


def owner_of(path):
    repo = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(path))))
    handoff = {"path": os.path.abspath(path), "repo": repo, "to": addressees(head(path))}
    _, ledger, pick, scores = owner_picks([handoff], sweep_repos(), recent_chats(), always=True)[0]
    return dict(pick or {}, path=handoff["path"], ledger=ledger, evidence=scores)


if __name__ == "__main__":
    if sys.argv[1:2] == ["--owner"]:
        for path in sys.argv[2:]:
            print(json.dumps(owner_of(path), ensure_ascii=False))
        sys.exit(0)
    if sys.argv[1:2] == ["--outside"]:
        for path in sys.argv[2:]:
            for repo in outside_repos(path, sweep_repos()):
                print(repo)
        sys.exit(0)
    found = open_handoffs()
    for item in owner_batches(found) if sys.argv[1:] == ["--batches"] else found:
        print(json.dumps(item, ensure_ascii=False))
