
import datetime
import glob
import json
import os
import re
import subprocess
import time

from fix_commit import main_checkout, memo_get, memo_put
import keepalive
import limit_hit

MENUS = "menus"
MENU_FILES = ("token-map/tokenmap/tracking.py", "token-map/tokenmap/pie.py", "llm-legs/hammerspoon/token-tracking.lua",
              "llm-legs/hammerspoon/doctors.lua", "llm-legs/bin/*-doctor")
SHARE_RISE = 1.5
RULE = "spend_audit"
GROUP = "Spend"
DAYS_KEPT = 35
VERDICTS = ("cut", "kept", "trade")
TOKENMAP_S = 180
SPEED_LANDING = re.compile(r"^merge \S*harness-speed-")


def tracking_path(home):
    return os.environ.get("SPEND_TRACKING") or os.path.join(home, ".local", "share", "tokenmap", "tracking.json")


def ledger_path(root):
    return os.environ.get("SPEND_LEDGER") or os.path.join(root, "share", "spend-ledger.json")


def read_json(path, default=None):
    try:
        with open(path, encoding="utf-8") as handle:
            return json.load(handle)
    except (OSError, ValueError):
        return default


def jsonl_row(line):
    """The object one journal line holds; None for a line that is not JSON or not an object."""
    try:
        row = json.loads(line)
    except ValueError:
        return None
    return row if isinstance(row, dict) else None


def read_jsonl(path):
    rows = []
    try:
        with open(path, encoding="utf-8", errors="replace") as handle:
            for line in handle:
                row = jsonl_row(line)
                if row is not None:
                    rows.append(row)
    except OSError:
        pass
    return rows


def load_ledger(root):
    ledger = read_json(ledger_path(root), {})
    return {r["id"]: r for r in (ledger.get("rows") if isinstance(ledger, dict) else None) or ()
            if isinstance(r, dict) and r.get("id")}


def epoch(text):
    try:
        text = str(text)
        return datetime.datetime.fromisoformat(text[:-1] + "+00:00" if text.endswith("Z") else text).timestamp()
    except ValueError:
        return None


def file_texts():
    cache = {}

    def read(path):
        if path not in cache:
            try:
                with open(path, errors="replace") as handle:
                    cache[path] = handle.read(1 << 20)
            except OSError:
                cache[path] = ""
        return cache[path]
    return read


def delta(cur, prev):
    if not prev:
        return "new" if cur else "0%"
    ratio = cur / prev
    return "×%d" % round(ratio) if ratio >= 10 else "%+d%%" % round((ratio - 1) * 100)


def components(payload, repos):
    """The menus check first, then each harness job whose latest run loaded Egor's configuration (tokenmap's
    harness_index.loaded), the cache keepalive while its pings cost more than they saved or it missed chats, then
    every Fee source of tokenmap's Fee index, largest first: its share of Claude spend as the menu shows it, the same
    as its basis for the due and proof rules, its plain Δ."""
    index = harness_index(payload) or {}
    sources = [s for s in index.get("sources") or () if isinstance(s, dict)]
    claude = float(index.get("claude") or 0)
    menus = sorted({f for pattern in MENU_FILES for f in glob.glob(os.path.join(repos, pattern))})
    out = [{"key": MENUS, "label": "Token tracking and Doctors menus against what the night reads", "sources": menus,
            "share": 0.0, "basis": 0.0, "delta": ""}]
    for leak in index.get("loaded") or ():
        out.append({"key": "loaded:" + leak["source"], "label": "%s loaded the harness configuration" % leak["source"],
                    "sources": [], "share": round(100 * float(leak["tokens"]) / claude, 3) if claude else 0.0,
                    "basis": round(float(leak["tokens"]) / claude, 6) if claude else 0.0,
                    "delta": "%d runs, last %s" % (leak["runs"], leak["last"]), "last": leak["last"]})
    workers = worker_md_leak()
    if workers:
        out.append(workers)
    out += keepalive.components(time.time())
    for s in sorted(sources, key=lambda s: -float(s["charged"])):
        out.append({"key": "fee:" + s["source"], "label": "%s (%s)" % (s["source"], s["group"]), "sources": [],
                    "share": round(100 * float(s["charged"]) / claude, 3) if claude else 0.0,
                    "basis": round(float(s["charged"]) / claude, 6) if claude else 0.0,
                    "delta": delta(*map(float, s["plain"]))})
    return out


def worker_md_leak():
    """Workers as a loaded: component while the latest claudeb worker run whose transcript worker-run checked still
    loaded the user CLAUDE.md that claudeMdExcludes keeps out; None while that run is clean."""
    import time_budget  # imports this module at load

    checked = [r for r in read_jsonl(time_budget.worker_runs_path()) if isinstance(r.get("user_md_loaded"), bool)]
    latest = max(checked, key=lambda r: r.get("ended_at") or 0, default=None)
    if not latest or not latest["user_md_loaded"]:
        return None
    last = datetime.datetime.fromtimestamp(latest.get("ended_at") or 0, datetime.timezone.utc).isoformat()
    return {"key": "loaded:Workers", "label": "Workers loaded the chat's CLAUDE.md past bin/worker-run's claudeMdExcludes", "sources": [], "share": 0.0,
            "basis": 0.0, "delta": "%d of %d runs, last %s" % (sum(r["user_md_loaded"] for r in checked), len(checked),
                                                               last), "last": last}


def repo_path(path, repos):
    real, repos = os.path.realpath(path), os.path.realpath(repos)
    return os.path.relpath(real, repos) if real.startswith(os.path.join(repos, "")) else real


def blobs(paths):
    """{path: blob}; a doctor run's landing memo (fix_commit.use_memo) keeps each file's blob while its size and
    mtime hold, so git hashes only what changed."""
    real, sigs, out = [p for p in paths if os.path.isfile(p)], {}, {}
    for path in real:
        try:
            stat = os.stat(path)
        except OSError:
            continue
        sigs[path] = [stat.st_size, stat.st_mtime_ns]
        kept = memo_get("blob", path)
        if isinstance(kept, list) and kept[:2] == sigs[path]:
            out[path] = kept[2]
    ask = sorted({p for p in real if p not in out})
    if not ask:
        return {p: out[p] for p in real}
    try:
        found = subprocess.run(["git", "hash-object", "--"] + ask, capture_output=True, text=True, timeout=20, cwd="/")
    except (OSError, subprocess.SubprocessError) as error:
        limit_hit.expired("probe.git", error, "the content hashes of %d files: read as unknown" % len(ask),
                          'share/spend.py:["git", "hash-object", "--"]')
        return None
    hashes = found.stdout.split() if found.returncode == 0 else []
    if len(hashes) != len(ask):
        return None
    for path, blob in zip(ask, hashes):
        out[path] = blob
        if path in sigs:
            memo_put("blob", path, sigs[path] + [blob])
    return {p: out[p] for p in real}


def moved(row, held, repos=None, memo=None):
    """held None: git could not hash, so nothing moved; a source recorded None was absent at audit (a cut). Given
    repos (the directory the source keys are under), a source only Speed audit runs moved does not count."""
    if held is None:
        return False
    recorded = row.get("sources") if isinstance(row.get("sources"), dict) else {}
    recorded = {p: h for p, h in recorded.items() if h is not None}
    if recorded == held or repos is None:
        return recorded != held
    return foreign({p for p in set(recorded) | set(held) if recorded.get(p) != held.get(p)}, recorded,
                   run_start(row), repos, {} if memo is None else memo)


def run_start(row):
    """When the audit's run started, off the UTC stamp in its `by` (a night worktree is main as of then), else its
    audit time."""
    audited = epoch(row.get("audited_at"))
    stamp = re.search(r"\d{8}T\d{6}Z", str(row.get("by") or ""))
    started = datetime.datetime.strptime(stamp.group(), "%Y%m%dT%H%M%SZ").replace(
        tzinfo=datetime.timezone.utc).timestamp() if stamp else None
    return min(started, audited) if started and audited else audited


def foreign(keys, recorded, since, repos, memo):
    """Whether anything but a Speed audit run moved these sources (keys under repos) since its run started: a moved
    source counts unless every commit main took after the last one holding its recorded blob (none: every one since)
    came in a Speed audit landing, at least one did, and it has no uncommitted change. An audit records its night
    worktree's blobs, so its own rebased landing, sibling audits' edits and siblings landed on main after the
    worktree's base always differ from them. Unknown (no audit time, a path outside repos, no reflog) reads as
    moved."""
    if not since:
        return True
    for key in keys:
        name, _, rel = key.partition("/")
        found = None if os.path.isabs(key) or not rel else landings(os.path.join(repos, name), since, memo)
        if found is None or rel in found["dirty"] or any(rel.startswith(d) for d in found["dirty"] if d.endswith("/")):
            return True
        moves = [m for m in found["files"].get(rel, ()) if m[0] >= since]
        held = [i for i, m in enumerate(moves) if m[2] == recorded.get(key)]
        after = moves[held[-1] + 1:] if held else moves
        if not after or not all(m[1] for m in after):
            return True
    return False


def landing_memo(rows):
    """A block's landings memo, floored at its oldest audit run's start: an older since answers every later one."""
    return {None: min(filter(None, (run_start(r) for r in rows if isinstance(r, dict))), default=None)}


def landings(top, since, memo):
    """{"files": {path: [(landed_at, by_speed, blob)]}, "dirty": {path}} of top's main checkout: every commit main
    took after `since`, oldest first, with the blob it left each path at, off main's reflog: a move lands the
    first-parent commits after the move before it; a `merge …harness-speed-…` move is a Speed audit run's landing.
    None without a reflog. A memo from landing_memo reads from its floor, so one read answers every later since."""
    since = min(since, memo.get(None) or since)
    held = memo.get(top)
    if held is not None and held[0] <= since:
        return held[1]
    memo[top] = (since, None)
    ref = git_lines(top, "symbolic-ref", "-q", "HEAD")
    moves = []
    for line in git_lines(top, "log", "-g", "--date=unix", "--format=%H %gd %gs", ref[0]) or () if ref else ():
        stamp = re.match(r"(\w+) \S*@\{(\d+)\} ?(.*)", line)
        if stamp:
            moves.append((stamp.group(1), int(stamp.group(2)), bool(SPEED_LANDING.match(stamp.group(3)))))
    kept = [m for m in moves if m[1] >= since]
    base = next((m[0] for m in moves if m[1] < since), None)
    if not kept or base is None and len(kept) < 2:
        return None
    if base is None:
        base = kept.pop()[0]
    order, files = [], {}
    for line in git_lines(top, "log", "--first-parent", "-m", "--no-renames", "--no-abbrev", "--format=%x01%H",
                          "--raw", "%s..%s" % (base, kept[0][0])) or ():
        if line.startswith("\x01"):
            order.append(line[1:])
        elif line.startswith(":") and "\t" in line and order:
            files.setdefault(order[-1], []).append((line.split("\t", 1)[1], line.split()[3]))
    status = git_lines(top, "status", "--porcelain", "--no-renames")
    if status is None:
        return None
    order.reverse()
    pos, landed = {c: i for i, c in enumerate(order)}, {}
    for sha, at, speed in reversed(kept):
        i = pos.get(sha, -1)
        while i >= 0 and order[i] not in landed:
            landed[order[i]] = (at, speed)
            i -= 1
    out = {"files": {}, "dirty": {line[3:] for line in status if len(line) > 3}}
    for commit in order:
        for path, blob in files.get(commit, ()) if commit in landed else ():
            out["files"].setdefault(path, []).append(landed[commit] + (blob,))
    memo[top] = (since, out)
    return out


def git_lines(top, *args):
    try:
        out = subprocess.run(["git", "-C", top] + list(args), capture_output=True, text=True, timeout=20)
    except (OSError, subprocess.SubprocessError) as error:
        limit_hit.expired("probe.git", error, "main's landings in %s: sources read as moved" % top,
                          'share/spend.py:["git", "-C", top] + list(args)')
        return None
    return out.stdout.splitlines() if out.returncode == 0 else None


def due(component, row, held, repos=None, memo=None):
    if not row:
        return "never audited"
    if moved(row, held, repos, memo):
        return "source changed"
    if row.get("verdict") == "cut" and (epoch(component.get("last")) or 0) > (epoch(row.get("audited_at")) or 0):
        return "still loading after the cut"
    share = row.get("share")
    if isinstance(share, (int, float)) and share > 0 and component["basis"] >= SHARE_RISE * share:
        return "share ×%.1f since audit" % (component["basis"] / share)
    return None


def harness_index(payload):
    found = payload.get("harness_index") if isinstance(payload, dict) else None
    return found if isinstance(found, dict) else None


def index_value(index):
    value = (index or {}).get("value")
    return round(float(value), 2) if isinstance(value, (int, float)) else None


def part_prices(index, key):
    """The cells of tokenmap's harness_index a Fee source is made of: {"consumer · leaf": [tasks, price]} of this
    window. The menus check has none."""
    source = key[len("fee:"):] if key.startswith("fee:") else None
    return {"%s · %s" % (c.get("consumer"), c.get("leaf")): [float(c["units"][0]), float(c["price"][0])]
            for c in (index or {}).get("cells") or ()
            if isinstance(c, dict) and source and c.get("source") == source
            and isinstance(c.get("units"), list) and isinstance(c.get("price"), list)}


def proof(c, row, index, made):
    """An audited component measured after its audit: its share and its part's price (this window's units at the
    audit's prices as the base) against the audit; proven when either fell."""
    audited = epoch(row.get("audited_at"))
    if not audited or made <= audited:
        return None
    then, now = row.get("prices") if isinstance(row.get("prices"), dict) else {}, part_prices(index, c["key"])
    base = sum(units * float(then[z]) for z, (units, _) in now.items() if isinstance(then.get(z), (int, float)))
    price = round(sum(units * price for z, (units, price) in now.items() if isinstance(then.get(z), (int, float)))
                  / base, 2) if base > 0 else None
    held = row.get("share")
    share = round(c["basis"] / float(held), 2) if isinstance(held, (int, float)) and held > 0 else None
    return {"share": share, "price": price, "proven": any(r is not None and r < 1 for r in (share, price)),
            "verdict": row.get("verdict"), "audited_at": row.get("audited_at")}


def proof_text(shown):
    if not shown:
        return "not measured since"
    return "share ×%s · price ×%s of audit · %s" % ("–" if shown["share"] is None else shown["share"],
                                                     "–" if shown["price"] is None else shown["price"],
                                                     "proven" if shown["proven"] else "not proven")


def day_value(day, cmd):
    """tokenmap's 7-day window ending with the day, the live reading's window then."""
    first = datetime.date.fromisoformat(day) - datetime.timedelta(days=6)
    after = datetime.date.fromisoformat(day) + datetime.timedelta(days=1)
    # Nobody waits on a backfill, and harness-doctor's launchd job is Standard at Nice 10 only.
    out = subprocess.run(["/usr/bin/nice", "-n", "19", *cmd, "tracking", "--since", first.isoformat(), "--until",
                          after.isoformat(), "--json"],
                         capture_output=True, text=True, timeout=TOKENMAP_S, stdin=subprocess.DEVNULL, check=True)
    return index_value(harness_index(json.loads(out.stdout)))


def tokenmap_cmd(home):
    """Live only: a fixture tracking file with no fixture tokenmap never reaches the live index."""
    if os.environ.get("SPEND_TOKENMAP"):
        return os.environ["SPEND_TOKENMAP"].split()
    return None if os.environ.get("SPEND_TRACKING") else [os.path.join(home, ".local", "bin", "tokenmap")]


def backfill(history, closed, through, now, local_day, home):
    """One completed day a run whose value is missing or was read intraday takes the closed day's value."""
    cmd = tokenmap_cmd(home)
    if not cmd:
        return
    for back in range(1, 8):
        day = local_day(now - back * 86400)
        end = datetime.datetime.combine(datetime.date.fromisoformat(day) + datetime.timedelta(days=1),
                                        datetime.time()).timestamp()
        if day not in closed and end <= through:
            try:
                history[day] = day_value(day, cmd)
                closed.append(day)
            except subprocess.TimeoutExpired:
                limit_hit.hit("spend.tokenmap", TOKENMAP_S, "s", "defer",
                              "the closed-day spend value of %s: retried next run" % day, "share/spend.py:TOKENMAP_S = ")
            except (OSError, subprocess.SubprocessError, ValueError):
                pass
            return


NAME_CELLS = 25


def menu_name(key):
    """An audit row's name leads it in one padded column: the doctors menu clips a row at 64 cells (doctors.lua
    ROW_CELLS), so a name printed after the numbers never showed. Leading path segments go first when it is long."""
    parts = key.split("/")
    while len(parts) > 1 and len("/".join(parts)) > NAME_CELLS:
        parts.pop(0)
    name = "/".join(parts)
    return (name if len(name) <= NAME_CELLS else name[:NAME_CELLS - 1] + "…").ljust(NAME_CELLS)


def named(c):
    if c["key"] == MENUS:
        return c["label"]
    return "%.*f %% of Claude spend · %s · %s%s" % (1 if c["share"] >= 1 else 2, c["share"], c["label"],
                                                     "" if "last" in c else "Δ ", c["delta"])


def problem(c, why, at):
    fact = "%s · audit due: %s" % (named(c), why)
    return {"id": "spend:" + c["key"], "rule": RULE, "state": "watch", "fact": fact, "value": c["share"],
            "limit": None, "unit": "% of Claude spend", "window_h": 168, "exposure": 0, "count": None,
            "first_seen": at, "last_seen": at, "evidence": [], "ledger": None, "group": GROUP,
            "spend": {"component": c["key"], "label": c["label"], "sources": c["sources"], "share": c["share"],
                      "basis": c["basis"], "delta": c["delta"], "due": why}}


def lines(found, rows, reasons, proofs):
    out = []
    for c in found:
        row, shown = rows.get(c["key"]), proofs.get(c["key"])
        tail = "audit due: " + reasons[c["key"]] if reasons.get(c["key"]) \
            else "%s %s · %s" % (row.get("verdict"), str(row.get("audited_at"))[:10], proof_text(shown))
        out.append([0, "" if reasons.get(c["key"]) else "d", False, "%s · %s" % (named(c), tail)])
    return out


def collect(now, state, write, home, repos, root, local_day):
    """The `spend` section: status, tokenmap's harness index as the value with its daily history, problems (one per
    component whose audit is due: the menus check, each Fee source), the night's queue (bin/doctor-fix takes its slot share),
    audit proofs, menu lines. A stale or missing tracking.json or harness_index reads nodata: never an old number as
    current."""
    history = state["index_by_day"] = {d: v for d, v in (state.get("index_by_day") or {}).items()
                                       if d >= local_day(now - DAYS_KEPT * 86400)}
    closed = state["index_closed"] = [d for d in state.get("index_closed") or () if d in history]
    out = {"status": "nodata", "as_of_s": int(now), "index": None, "index_by_day": history, "problems": [],
           "selection": [], "issues": [], "proofs": {}, "menu": []}
    path = tracking_path(home)
    payload = read_json(path, None)
    made = epoch((payload or {}).get("generated_at")) if isinstance(payload, dict) else None
    if made is None:
        out["head"] = "no tracking.json at %s" % path
        return out
    if now - made > float(payload.get("stale_after_hours") or 26) * 3600:
        out["head"] = "tracking.json stale since %s" % time.strftime("%d %b %H:%M", time.localtime(made))
        return out
    index = harness_index(payload)
    if index is None:
        out["head"] = "no harness_index in tracking.json"
        return out
    if state.get("index_definition") != index.get("definition"):
        history.clear()
        closed.clear()
        state["index_definition"] = index.get("definition")
    found = components(payload, repos)
    rows = load_ledger(root)
    held = blobs([s for c in found if c["key"] in rows for s in c["sources"]])
    memo = landing_memo(rows.get(c["key"]) for c in found)
    reasons = {c["key"]: due(c, rows.get(c["key"]), None if held is None else {
        repo_path(s, repos): h for s, h in held.items() if s in c["sources"]}, repos, memo) for c in found}
    proofs = {c["key"]: proof(c, rows[c["key"]], index, made) for c in found
              if c["key"] in rows and not reasons.get(c["key"])}
    at = datetime.datetime.fromtimestamp(made).astimezone().isoformat(timespec="seconds")
    out["problems"] = [problem(c, reasons[c["key"]], at) for c in found if reasons.get(c["key"])]
    out["selection"] = [p["id"] for p in out["problems"]]
    out["issues"] = [[p["value"], p["spend"]["label"]] for p in out["problems"] if p["spend"]["component"] != MENUS][:3]
    value = index_value(index)
    out.update(status="watch" if out["problems"] else "ok", index=value, change=index.get("change"),
               proofs={k: v for k, v in proofs.items() if v})
    if write:
        if value is not None and local_day(made) not in closed:
            history[local_day(made)] = value
        backfill(history, closed, epoch(payload.get("data_through")) or made, now, local_day, home)
    coverage = index.get("coverage")
    out["head"] = "%s%s · %d audit%s due" % (
        "Fee index %.2f (%s)" % (value, index.get("change") or "–") if value is not None
        else "Fee index: too little use",
        " · Fee %.1f %% of spend" % (100 * coverage) if isinstance(coverage, (int, float)) else "",
        len(out["problems"]), "" if len(out["problems"]) == 1 else "s")
    pings = keepalive.menu_line(now)
    out["menu"] = lines(found, rows, reasons, out["proofs"]) + [[0, "d", False, pings]] * bool(pings) + [
        [0, "d", False, "tracking.json %s · 7 days" % time.strftime("%d %b %H:%M", time.localtime(made))]]
    return out


def restate(problems, rows):
    """A component audited after Spend measured it is settled: a night close reruns Harness on its own branch's
    spend ledger."""
    out = []
    for p in problems:
        row = rows.get(((p.get("spend") or {}).get("component"))) if p.get("rule") == RULE else None
        audited, measured = epoch((row or {}).get("audited_at")), epoch(p.get("last_seen"))
        if not (audited and measured and audited >= measured):
            out.append(p)
    return out


def zero_option(text):
    """What removing the component whole saves and loses: every audit prices it, whatever it then cuts."""
    if not str(text or "").strip():
        raise SystemExit("--zero is required: what removing the component whole saves and what it loses, one line")
    return str(text).strip()


def record(root, home, repos, key, verdict, note, zero, by, worktrees):
    if verdict not in VERDICTS:
        raise SystemExit("verdict must be one of %s" % ", ".join(VERDICTS))
    zero = zero_option(zero)
    payload = read_json(tracking_path(home), None)
    if not isinstance(payload, dict):
        raise SystemExit("no tracking.json at %s" % tracking_path(home))
    c = next((c for c in components(payload, repos) if c["key"] == key), None)
    if not c and verdict == "cut" and key.startswith("loaded:"):
        # The proof of this cut is the job's next run gone bare, which drops it from the index.
        c = {"label": "%s loaded the harness configuration" % key[len("loaded:"):], "basis": 0.0, "sources": []}
    if not c:
        raise SystemExit("no Spend component %s in tracking.json" % key)
    return save_row(root, {
        "id": key, "title": c["label"], "audited_at": datetime.datetime.now().astimezone().isoformat(timespec="seconds"),
        "by": by, "share": c["basis"],
        "prices": {z: price for z, (_, price) in part_prices(harness_index(payload), key).items()},
        "sources": source_blobs(root, repos, c["sources"], worktrees), "verdict": verdict, "zero": zero, "note": note})


def source_blobs(root, repos, sources, worktrees):
    """Each source's blob as the night worktree holding its repository has it, keyed by its path under repos."""
    mains = {main_checkout(w): os.path.realpath(w) for w in [root] + list(worktrees)}
    paths = {}
    for source in sources:
        real = os.path.realpath(source)
        top = next((m for m in mains if real.startswith(os.path.join(m, ""))), None)
        paths[repo_path(source, repos)] = os.path.join(mains[top], os.path.relpath(real, top)) if top else real
    held = blobs(list(paths.values()))
    if held is None:
        raise SystemExit("git could not hash %s: nothing recorded, record the audit again" % ", ".join(sorted(paths)))
    return {p: held.get(real) for p, real in sorted(paths.items())}


def save_row(root, row):
    path = ledger_path(root)
    ledger = read_json(path, None) if os.path.exists(path) else {}
    if not isinstance(ledger, dict):
        raise SystemExit("%s is no JSON object (conflict markers?): fix it, then record the audit" % path)
    ledger.setdefault("owner", "Harness Doctor")
    ledger["rows"] = [r for r in ledger.get("rows") or () if isinstance(r, dict) and r.get("id") != row["id"]] + [row]
    with open(path + ".tmp", "w") as handle:
        handle.write(json.dumps(ledger, indent=1, ensure_ascii=False) + "\n")
    os.replace(path + ".tmp", path)
    return row
