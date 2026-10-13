
import datetime
import glob
import json
import os
import re
import subprocess
import time

from fix_commit import main_checkout
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


def read_jsonl(path):
    rows = []
    try:
        with open(path, encoding="utf-8", errors="replace") as handle:
            for line in handle:
                try:
                    row = json.loads(line)
                except ValueError:
                    continue
                if isinstance(row, dict):
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
        return datetime.datetime.fromisoformat(str(text)).timestamp()
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
    """The menus check first, then every Fee source of tokenmap's Fee index, largest first: its share of Fee as the menu
    shows it, its basis (share of Claude spend) for the due and proof rules, its plain Δ."""
    index = harness_index(payload) or {}
    sources = [s for s in index.get("sources") or () if isinstance(s, dict)]
    fee, claude = sum(float(s["charged"]) for s in sources), float(index.get("claude") or 0)
    menus = sorted({f for pattern in MENU_FILES for f in glob.glob(os.path.join(repos, pattern))})
    out = [{"key": MENUS, "label": "Token tracking and Doctors menus against what the night reads", "sources": menus,
            "share": 0.0, "basis": 0.0, "delta": ""}]
    for s in sorted(sources, key=lambda s: -float(s["charged"])):
        out.append({"key": "fee:" + s["source"], "label": "%s (%s)" % (s["source"], s["group"]), "sources": [],
                    "share": round(100 * float(s["charged"]) / fee, 3) if fee else 0.0,
                    "basis": round(float(s["charged"]) / claude, 6) if claude else 0.0,
                    "delta": delta(*map(float, s["plain"]))})
    return out


def repo_path(path, repos):
    real, repos = os.path.realpath(path), os.path.realpath(repos)
    return os.path.relpath(real, repos) if real.startswith(os.path.join(repos, "")) else real


def blobs(paths):
    real = [p for p in paths if os.path.isfile(p)]
    if not real:
        return {}
    try:
        out = subprocess.run(["git", "hash-object", "--"] + real, capture_output=True, text=True, timeout=20, cwd="/")
    except (OSError, subprocess.SubprocessError) as error:
        limit_hit.expired("probe.git", error, "the content hashes of %d files: read as unknown" % len(real),
                          'share/spend.py:["git", "hash-object", "--"]')
        return None
    hashes = out.stdout.split() if out.returncode == 0 else []
    return dict(zip(real, hashes)) if len(hashes) == len(real) else None


def moved(row, held):
    """held None: git could not hash, so nothing moved; a source recorded None was absent at audit (a cut)."""
    if held is None:
        return False
    recorded = row.get("sources") if isinstance(row.get("sources"), dict) else {}
    return {p: h for p, h in recorded.items() if h is not None} != held


def due(component, row, held):
    if not row:
        return "never audited"
    if moved(row, held):
        return "source changed"
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


def named(c):
    return c["label"] if c["key"] == MENUS else "%.1f %% of Fee · %s · Δ %s" % (c["share"], c["label"], c["delta"])


def problem(c, why, at):
    fact = "%s · audit due: %s" % (named(c), why)
    return {"id": "spend:" + c["key"], "rule": RULE, "state": "watch", "fact": fact, "value": c["share"],
            "limit": None, "unit": "% of Fee", "window_h": 168, "exposure": 0, "count": None,
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
    reasons = {c["key"]: due(c, rows.get(c["key"]), None if held is None else {
        repo_path(s, repos): h for s, h in held.items() if s in c["sources"]}) for c in found}
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
    out["menu"] = lines(found, rows, reasons, out["proofs"]) + [
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
