
import datetime
import json
import os
import re
import subprocess
import time

from fix_commit import main_checkout

PARTS = {"hook": ("hooks", None), "startup": ("startup", None), "spawn": ("startup", "subagent"),
         "rewrites": ("rewrites", None)}
SHARE_RISE = 1.5
HOOK_SECTIONS = ("Blocked calls", "Stop-hook re-answers", "Injected text")
RULE = "spend_audit"
GROUP = "Spend"
DAYS_KEPT = 35
VERDICTS = ("cut", "kept", "trade")
TOKENMAP_S = 180


def tracking_path(home):
    return os.environ.get("SPEND_TRACKING") or os.path.join(home, ".local", "share", "tokenmap", "tracking.json")


def ledger_path(root):
    return os.environ.get("SPEND_LEDGER") or os.path.join(root, "share", "spend-ledger.json")


def read_json(path, default):
    try:
        with open(path) as handle:
            return json.load(handle)
    except (OSError, ValueError):
        return default


def load_ledger(root):
    ledger = read_json(ledger_path(root), {})
    return {r["id"]: r for r in (ledger.get("rows") if isinstance(ledger, dict) else None) or ()
            if isinstance(r, dict) and r.get("id")}


def epoch(text):
    try:
        return datetime.datetime.fromisoformat(str(text)).timestamp()
    except ValueError:
        return None


def amount(cell):
    found = re.fullmatch(r"([\d,.]+)\s*([kM]?)", str(cell or "").strip())
    return float(found.group(1).replace(",", "")) * {"": 1, "k": 1e3, "M": 1e6}[found.group(2)] if found else 0.0


def section(row, title):
    return [item for part in (row or {}).get("sections") or () if part.get("title") == title
            for item in part.get("rows") or () if not item.get("dim")]


def hook_files(scripts):
    files = {}
    tops = sorted({os.path.dirname(os.path.realpath(s)) for s in scripts if s})
    for folder in tops + sorted(os.path.join(t, d) for t in tops for d in os.listdir(t)
                                if d.endswith(".d") and os.path.isdir(os.path.join(t, d))):
        for name in sorted(os.listdir(folder)):
            if os.path.isfile(os.path.join(folder, name)):
                files.setdefault(name, os.path.realpath(os.path.join(folder, name)))
    return files


def script_name(label, files, texts):
    """tokenmap's hook label (`name`, `Event [tag]`, `Event · opening words`) -> the script's file name; opening words
    resolve only when exactly one hook file holds them (tokenmap folds digits to N), else the label stays its own."""
    tag = re.search(r"\[([^\]]+)\]", label)
    _, dot, tail = label.partition(" · ")
    name = tag.group(1) if tag else tail if dot else label
    for candidate in (name, name + ".sh"):
        if candidate in files:
            return candidate
    if tag or re.fullmatch(r"[\w.-]+\.(?:sh|py)", name):
        return name
    if dot and tail:
        pattern = re.compile(r"\s+".join(re.sub(r"(?<![A-Za-z])N(?![A-Za-z])", r"\\d+", re.escape(word))
                                         for word in tail.split()))
        hits = [n for n, path in files.items() if pattern.search(texts(path))]
        if len(hits) == 1:
            return hits[0]
    return label


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


def components(payload, files, texts):
    rows = {r.get("key"): r for r in payload.get("rows") or () if isinstance(r, dict)}
    spend, bench = rows.get("spend") or {}, rows.get("bench") or {}
    total = float(spend.get("cur") or 0)
    base = [float(spend.get(k) or 0) - float(bench.get(k) or 0) for k in ("cur", "prev")]
    found = {}

    def add(key, label, cur, prev, sources=(), target=True):
        c = found.setdefault(key, {"key": key, "label": label, "cur": 0.0, "prev": 0.0, "sources": set(),
                                   "target": target})
        c["cur"], c["prev"] = c["cur"] + cur, c["prev"] + prev
        c["sources"].update(sources)

    for title in HOOK_SECTIONS:
        for item in section(rows.get("hooks"), title):
            name = script_name(str(item.get("label") or ""), files, texts)
            cells = item.get("cells") or ["", ""]
            add("hook:" + name, name, amount(cells[0]), amount(cells[1]), [files[name]] if name in files else ())
    if rows.get("resumes"):
        add("resumes", "worker cold resumes", float(rows["resumes"].get("cur") or 0),
            float(rows["resumes"].get("prev") or 0))
    for item in section(rows.get("rewrites"), "By cause"):
        label = str(item.get("label") or "")
        add("rewrites:" + label, "re-writes " + label, amount(item["cells"][0]), amount(item["cells"][1]),
            target=item.get("avoidable") is True)
    startup = rows.get("startup") or {}
    spawns = section(startup, "Subagent spawns, by agent")
    for item in spawns:
        add("spawn:" + str(item.get("label")), "spawn " + str(item.get("label")), amount(item["cells"][0]),
            amount(item["cells"][1]))
    contexts = [max(float(startup.get(k) or 0) - sum(amount(i["cells"][side]) for i in spawns), 0.0)
                for side, k in ((0, "cur"), (1, "prev"))]
    parts = section(startup, "Per context that loads it (avg)")
    sums = [sum(amount(i["cells"][side]) for i in parts) for side in (0, 1)]
    for item in parts:
        add("startup:" + str(item.get("label")), "startup " + str(item.get("label")),
            *[contexts[side] * amount(item["cells"][side]) / sums[side] if sums[side] else 0.0 for side in (0, 1)])
    for item in section(rows.get("hidden"), "Compaction summaries, by zone"):
        add("compaction", "compaction summaries", amount(item["cells"][0]), amount(item["cells"][1]), target=False)
    out = []
    for c in [c for c in found.values() if c["cur"] > 0]:
        basis = c["cur"] / base[0] if base[0] > 0 else 0.0
        out.append(dict(c, sources=sorted(c["sources"]), share=round(100 * c["cur"] / total, 3) if total else 0.0,
                        basis=round(basis, 6), delta=delta(basis, c["prev"] / base[1] if base[1] > 0 else 0.0)))
    return sorted(out, key=lambda c: (-c["share"], c["key"]))


def repo_path(path, repos):
    real, repos = os.path.realpath(path), os.path.realpath(repos)
    return os.path.relpath(real, repos) if real.startswith(os.path.join(repos, "")) else real


def blobs(paths):
    real = [p for p in paths if os.path.isfile(p)]
    if not real:
        return {}
    try:
        out = subprocess.run(["git", "hash-object", "--"] + real, capture_output=True, text=True, timeout=20, cwd="/")
    except (OSError, subprocess.SubprocessError):
        return {}
    hashes = out.stdout.split() if out.returncode == 0 else []
    return dict(zip(real, hashes)) if len(hashes) == len(real) else {}


def moved(row, held):
    recorded = row.get("sources") if isinstance(row.get("sources"), dict) else {}
    return set(recorded) != set(held) or any(recorded[p] != held[p] for p in held)


def due(component, row, held):
    if not row:
        return "never audited"
    if moved(row, held):
        return "source changed"
    share = row.get("share")
    if isinstance(share, (int, float)) and component["basis"] > 0 and component["basis"] >= SHARE_RISE * share:
        return "share ×%.1f since audit" % (component["basis"] / share if share else float("inf"))
    return None


def harness_index(payload):
    found = payload.get("harness_index") if isinstance(payload, dict) else None
    return found if isinstance(found, dict) else None


def index_value(index):
    value = (index or {}).get("value")
    return round(float(value), 2) if isinstance(value, (int, float)) else None


def part_prices(index, key):
    """The zones of tokenmap's harness_index part a component belongs to: {zone: [units, price]} of this window."""
    part, zone = PARTS.get(key.split(":", 1)[0], (None, None))
    return {str(p.get("zone")): [float(p["units"][0]), float(p["price"][0])] for p in (index or {}).get("parts") or ()
            if isinstance(p, dict) and part and p.get("part") == part and zone in (None, p.get("zone"))
            and isinstance(p.get("units"), list) and isinstance(p.get("price"), list)}


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
    try:
        out = subprocess.run(cmd + ["tracking", "--since", first.isoformat(), "--until", after.isoformat(), "--json"],
                             capture_output=True, text=True, timeout=TOKENMAP_S, stdin=subprocess.DEVNULL)
        return index_value(harness_index(json.loads(out.stdout))) if out.returncode == 0 else None
    except (OSError, subprocess.SubprocessError, ValueError):
        return None


def tokenmap_cmd(home):
    """Live only: a fixture tracking file with no fixture tokenmap never reaches the live index."""
    if os.environ.get("SPEND_TOKENMAP"):
        return os.environ["SPEND_TOKENMAP"].split()
    return None if os.environ.get("SPEND_TRACKING") else [os.path.join(home, ".local", "bin", "tokenmap")]


def backfill(history, through, now, local_day, home):
    cmd = tokenmap_cmd(home)
    if not cmd:
        return
    for back in range(1, 8):
        day = local_day(now - back * 86400)
        end = datetime.datetime.combine(datetime.date.fromisoformat(day) + datetime.timedelta(days=1),
                                        datetime.time()).timestamp()
        if day not in history and end <= through:
            history[day] = day_value(day, cmd)
            return


def problem(c, why, at):
    fact = "%s · %.1f %% of spend · Δ %s · audit due: %s" % (c["label"], c["share"], c["delta"], why)
    return {"id": "spend:" + c["key"], "rule": RULE, "state": "watch", "fact": fact, "value": c["share"],
            "limit": None, "unit": "% of spend", "window_h": 168, "exposure": 0, "count": None,
            "first_seen": at, "last_seen": at, "evidence": [], "ledger": None, "group": GROUP,
            "spend": {"component": c["key"], "label": c["label"], "sources": c["sources"], "share": c["share"],
                      "basis": c["basis"], "delta": c["delta"], "due": why}}


def lines(found, rows, reasons, proofs):
    out = []
    for c in found:
        row, shown = rows.get(c["key"]), proofs.get(c["key"])
        tail = "never targeted" if not c["target"] else "audit due: " + reasons[c["key"]] if reasons.get(c["key"]) \
            else "%s %s · %s" % (row.get("verdict"), str(row.get("audited_at"))[:10], proof_text(shown))
        out.append([0, "" if reasons.get(c["key"]) else "d", False,
                    "%.1f %% · %s · Δ %s · %s" % (c["share"], c["label"], c["delta"], tail)])
    return out


def collect(now, state, write, scripts, home, repos, root, local_day):
    """The `spend` section: status, tokenmap's harness index as the value with its daily history, problems (one per
    harness-owned component whose audit is due), the night's one selection, audit proofs, menu lines. A stale or
    missing tracking.json or harness_index reads nodata: never an old number as current."""
    state.pop("spend_by_day", None)
    history = state["index_by_day"] = {d: v for d, v in (state.get("index_by_day") or {}).items()
                                       if d >= local_day(now - DAYS_KEPT * 86400)}
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
    files, texts = hook_files(scripts), file_texts()
    found = components(payload, files, texts)
    rows = load_ledger(root)
    held = blobs([s for c in found if c["target"] and c["key"] in rows for s in c["sources"]])
    reasons = {}
    for c in found:
        if c["target"]:
            reasons[c["key"]] = due(c, rows.get(c["key"]), {repo_path(s, repos): h for s, h in held.items()
                                                             if s in c["sources"]})
    proofs = {c["key"]: proof(c, rows[c["key"]], index, made) for c in found
              if c["target"] and c["key"] in rows and not reasons.get(c["key"])}
    at = datetime.datetime.fromtimestamp(made).astimezone().isoformat(timespec="seconds")
    out["problems"] = [problem(c, reasons[c["key"]], at) for c in found if reasons.get(c["key"])]
    out["selection"] = [p["id"] for p in out["problems"][:1]]
    out["issues"] = [[p["value"], p["spend"]["label"]] for p in out["problems"][:3]]
    value = index_value(index)
    out.update(status="watch" if out["problems"] else "ok", index=value, change=index.get("change"),
               tone=index.get("tone"), generated_at=payload["generated_at"],
               proofs={k: v for k, v in proofs.items() if v},
               components=[{k: c[k] for k in ("key", "share", "delta", "target")} for c in found])
    if write:
        if value is not None:
            history[local_day(made)] = value
        backfill(history, epoch(payload.get("data_through")) or made, now, local_day, home)
    coverage = index.get("coverage")
    out["head"] = "%s%s · %d audit%s due" % (
        "index %.2f (%s)" % (value, index.get("change") or "–") if value is not None
        else "harness index: too little use",
        " · %.1f %% of spend priced" % (100 * coverage) if isinstance(coverage, (int, float)) else "",
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


def record(root, home, repos, scripts, key, verdict, note, by, worktrees):
    if verdict not in VERDICTS:
        raise SystemExit("verdict must be one of %s" % ", ".join(VERDICTS))
    payload = read_json(tracking_path(home), None)
    if not isinstance(payload, dict):
        raise SystemExit("no tracking.json at %s" % tracking_path(home))
    files = hook_files(scripts)
    c = next((c for c in components(payload, files, file_texts()) if c["key"] == key), None)
    if not c:
        raise SystemExit("no Spend component %s in tracking.json" % key)
    return save_row(root, {
        "id": key, "title": c["label"], "audited_at": datetime.datetime.now().astimezone().isoformat(timespec="seconds"),
        "by": by, "share": c["basis"],
        "prices": {z: price for z, (_, price) in part_prices(harness_index(payload), key).items()},
        "sources": source_blobs(root, repos, c["sources"], worktrees), "verdict": verdict, "note": note})


def source_blobs(root, repos, sources, worktrees):
    """Each source's blob as the night worktree holding its repository has it, keyed by its path under repos."""
    mains = {main_checkout(w): os.path.realpath(w) for w in [root] + list(worktrees)}
    paths = {}
    for source in sources:
        real = os.path.realpath(source)
        top = next((m for m in mains if real.startswith(os.path.join(m, ""))), None)
        paths[repo_path(source, repos)] = os.path.join(mains[top], os.path.relpath(real, top)) if top else real
    held = blobs(list(paths.values()))
    return {p: held.get(real) for p, real in sorted(paths.items())}


def save_row(root, row):
    path = ledger_path(root)
    ledger = read_json(path, {}) or {}
    ledger.setdefault("owner", "Harness Doctor")
    ledger["rows"] = [r for r in ledger.get("rows") or () if isinstance(r, dict) and r.get("id") != row["id"]] + [row]
    with open(path + ".tmp", "w") as handle:
        handle.write(json.dumps(ledger, indent=1, ensure_ascii=False) + "\n")
    os.replace(path + ".tmp", path)
    return row
