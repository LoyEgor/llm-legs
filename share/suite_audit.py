"""Suite audits, the Harness doctor's standing night job beside Spend: every suite of the sweep and night helper
repositories priced and ranked at wall-min/day over 7 days of run-suites' journal (every runner), CPU-min/day beside
it: a suite idles most of its wall, so CPU alone misses it. Test health's dead suites join the queue. An audit is
due when never done, when the suite or a tests/ helper it names has another blob than at audit, or when its CPU per
run reached 1.5x the audit's; a rise of 1.5x and 30 s between commits, or a new suite over 3x the median suite per
run, is due at once and names its commit. Audit rows live in Spend's ledger (share/spend-ledger.json) as
`suite:<repo>/<label>`."""

import datetime
import os
import re
import statistics
import subprocess
import time

import handoffs
import night_spend
import spend

RULE = "suite_audit"
GROUP = "Suite audits"
ROW = "suite:"
WINDOW_D = 7
CPU_RISE = 1.5
JUMP_S = 30.0
NEW_HEAVY = 3.0
SIDE_RUNS = 3
SHOWN = 10
# Median of 5 runs against the 20 before it on the same suite: p5 0.75 across runs.jsonl (2026-10-03..07), so a
# smaller ratio is no noise.
PROOF_RUNS, PROOF_RATIO = 5, 0.75
# CPU a run is the median of the last 20, not of the window, and CPU-min/day is it times the window's runs: a 7-day
# median still read 248 s for test_instruction_gate three days after its split had brought it to 42, which ranked it
# second in the queue (2026-10-08 audit: kept) and would have let an audit store and its proof credit the old cost.
RECENT_RUNS = 20


def repos():
    return handoffs.sweep_repos() + handoffs.helper_repos()


def runs(path, lo):
    """One sample per suite run ended after lo."""
    out = []
    for r in night_spend.rows(path):
        end = r.get("ended_at")
        if not isinstance(end, (int, float)) or end < lo or not isinstance(r.get("suites"), dict):
            continue
        root = str(r.get("repo_root") or r.get("repo") or "").rstrip("/")
        for name, s in r["suites"].items():
            if isinstance(s, dict) and isinstance(s.get("cpu_s"), (int, float)):
                out.append({"repo": os.path.basename(root), "name": name, "end": float(end), "cpu": float(s["cpu_s"]),
                            "wall": float(s["secs"]) if isinstance(s.get("secs"), (int, float)) else float(s["cpu_s"]),
                            "head": str(r.get("head") or ""), "worker": bool(r.get("worker_run")), "ok": s.get("rc") == 0})
    return sorted(out, key=lambda x: x["end"])


def suites(tops):
    found = {}
    for top in tops:
        folder = os.path.join(top, "tests")
        for name in sorted(os.listdir(folder)) if os.path.isdir(folder) else ():
            if name.startswith("test_") and name.endswith((".sh", ".py")) and os.path.isfile(os.path.join(folder, name)):
                found[(os.path.basename(top.rstrip("/")), name)] = (top, os.path.join(folder, name))
    return found


def sources(path):
    """The suite and every tests/ helper its text names."""
    folder = os.path.dirname(path)
    text = spend.file_texts()(path)
    out = [path]
    for sub in ("", "lib"):
        here = os.path.join(folder, sub)
        for name in sorted(os.listdir(here)) if os.path.isdir(here) else ():
            if not name.startswith(("test_", "e2e_")) and os.path.isfile(os.path.join(here, name)) \
                    and re.search(r"(?<![\w.-])%s(?![\w-])" % re.escape(name), text):
                out.append(os.path.join(here, name))
    return out


def git(top, *args):
    try:
        out = subprocess.run(["git", "-C", top] + list(args), capture_output=True, text=True, timeout=10)
    except (OSError, subprocess.SubprocessError):
        return ""
    return out.stdout.strip() if out.returncode == 0 else ""


def commit(top, rev):
    found = git(top, "log", "-1", "--format=%h %s", rev, "--")
    return "%s «%s»" % (found[:found.find(" ")], found[found.find(" ") + 1:][:60]) if " " in found else rev[:7]


def adds(top, lo):
    """{suite path: (commit, time)} of the suites a commit inside the window created, unless it split an existing
    suite: the other suite files it touched lost at least half the lines the new ones hold."""
    out, found = {}, []
    for line in git(top, "log", "--since=@%d" % lo, "--format=@%h %ct", "--numstat", "--summary", "--",
                    "tests/").splitlines():
        parts = line.split("\t")
        if line.startswith("@") and len(line[1:].split()) == 2:
            found.append({"at": tuple(line[1:].split()), "lines": {}, "created": set()})
        elif found and len(parts) == 3 and parts[1].isdigit():
            found[-1]["lines"][parts[2]] = (int(parts[0]), int(parts[1]))
        elif found and line.startswith(" create mode "):
            found[-1]["created"].add(line.split(" ", 4)[-1])
    for c in found:
        new = [n for n in c["created"] if os.path.basename(n).startswith("test_")]
        moved = sum(d for n, (_, d) in c["lines"].items() if n not in c["created"] and os.path.basename(n).startswith("test_"))
        if new and moved * 2 < sum(c["lines"].get(n, (0, 0))[0] for n in new):
            for name in new:
                out.setdefault(os.path.join(top, name), (c["at"][0], float(c["at"][1])))
    return out


def passing(history):
    """A failed run stops early: CPU per run reads passing runs while any exist."""
    return [h for h in history if h["ok"]] or history


def jump(history):
    """The first run of a commit after which CPU per run stayed >= 1.5x and >= 30 s over the runs before it."""
    history = passing(history)
    cpus = [h["cpu"] for h in history]
    if len(cpus) < 2 * SIDE_RUNS or max(cpus) < JUMP_S:
        return None
    best, seen = None, set()
    for i, h in enumerate(history):
        if h["head"] in seen or not h["head"]:
            continue
        seen.add(h["head"])
        if i < SIDE_RUNS or len(cpus) - i < SIDE_RUNS:
            continue
        before, after = statistics.median(cpus[:i]), statistics.median(cpus[i:])
        last = statistics.median(cpus[-SIDE_RUNS:])
        if min(after, last) >= CPU_RISE * before and after - before >= JUMP_S and (not best or after - before > best[0]):
            best = (after - before, h, before, after)
    return best and {"at": best[1]["end"], "head": best[1]["head"], "before": round(best[2], 1),
                     "after": round(best[3], 1), "prev": history[history.index(best[1]) - 1]["head"]}


def price(rows, found):
    by = {}
    for r in rows:
        by.setdefault((r["repo"], r["name"]), []).append(r)
    out = []
    for (repo, name), (top, path) in sorted(found.items()):
        history = by.get((repo, name))
        if not history:
            continue
        recent = passing(history)[-RECENT_RUNS:]
        p50, wall = statistics.median(h["cpu"] for h in recent), statistics.median(h["wall"] for h in recent)
        out.append({"key": "%s/%s" % (repo, os.path.splitext(name)[0]), "repo": repo,
                    "label": os.path.splitext(name)[0], "top": top, "path": path, "runs": len(history),
                    "cpu_min_day": round(p50 * len(history) / WINDOW_D / 60.0, 2), "p50": round(p50, 1),
                    "wall_min_day": round(wall * len(history) / WINDOW_D / 60.0, 2), "wall_p50": round(wall, 1),
                    "history": history})
    return sorted(out, key=lambda c: (-c["wall_min_day"], c["key"]))


def unrun(key, found):
    """A dead suite no run priced: its queue row at no cost."""
    return {"key": key, "repo": key.split("/")[0], "label": key.split("/", 1)[1], "top": found["top"],
            "path": found["path"], "runs": 0, "cpu_min_day": 0.0, "p50": 0.0, "wall_min_day": 0.0, "wall_p50": 0.0,
            "history": []}


def epoch(text):
    return spend.epoch(text) if text else None


def changed_at(top, paths, held, row):
    """When a moved source last changed: its last commit (a dropped one's removal), or its mtime while the change is
    uncommitted, now when a dropped one has neither."""
    recorded, base = row.get("sources") or {}, os.path.dirname(top.rstrip("/"))
    at = []
    for path in set(paths) | {os.path.join(base, k) for k in recorded if k not in held}:
        key = spend.repo_path(path, base)
        if recorded.get(key) != held.get(key):
            stamp = git(top, "log", "-1", "--format=%ct", "--", os.path.relpath(path, top))
            dirty = git(top, "status", "--porcelain", "--", os.path.relpath(path, top))
            at.append(os.path.getmtime(path) if (dirty or not stamp.isdigit()) and os.path.exists(path)
                      else float(stamp) if stamp.isdigit() and not dirty else time.time())
    return max(at, default=0.0)


def culprit(c, rise):
    """The newest commit between the last cheap run's and the first dear run's that touched the suite's sources, else
    the first dear run's own commit."""
    rels = [os.path.relpath(p, c["top"]) for p in c["sources"]]
    found = git(c["top"], "log", "-1", "--format=%H", "%s..%s" % (rise["prev"], rise["head"]), "--", *rels) \
        if rise["prev"] and rise["prev"] != rise["head"] else ""
    return commit(c["top"], found or rise["head"])


def due(c, row, held, median, new, dead=None):
    """(reason, at once, since): since is when the reason arose, so an audit recorded after it settles it."""
    audited = epoch((row or {}).get("audited_at")) or 0.0
    if dead and (not row or audited < dead["since"]):
        return dead.get("kind", "dead") + ": " + dead["reason"], False, dead["since"]
    rise = jump(c["history"])
    if rise and rise["at"] > audited:
        c["commit"] = culprit(c, rise)
        return ("CPU a run ×%.1f (%d → %d s) since %s" % (rise["after"] / rise["before"] if rise["before"] else 0,
                                                         rise["before"], rise["after"], c["commit"]), True, rise["at"])
    new = not row and median and c["p50"] > NEW_HEAVY * median and new.get(c["path"])
    if new:
        c["commit"] = commit(c["top"], new[0])
        return "new suite at ×%.1f the median suite a run, added in %s" % (c["p50"] / median, c["commit"]), True, new[1]
    if not row:
        return "never audited", False, 0.0
    if spend.moved(row, held):
        return "source changed", False, changed_at(c["top"], c["sources"], held, row)
    then = row.get("cpu_run")
    if isinstance(then, (int, float)) and then > 0 and c["p50"] >= CPU_RISE * then:
        return "CPU a run ×%.1f since audit" % (c["p50"] / then), False, max(c["history"][-1]["end"], audited + 1)
    return None


def proof(c, row):
    """An audited suite's p50 over the runs after its audit against the audit's: proven once PROOF_RUNS runs read
    PROOF_RATIO or less of it."""
    audited, then = epoch(row.get("audited_at")), row.get("cpu_run")
    after = [h["cpu"] for h in passing(c["history"]) if audited and h["end"] > audited]
    if not isinstance(then, (int, float)) or then <= 0 or len(after) < PROOF_RUNS:
        return {"runs": len(after), "need": PROOF_RUNS, "before": then, "after": None, "proven": False}
    now = round(statistics.median(after), 1)
    return {"runs": len(after), "need": PROOF_RUNS, "before": then, "after": now, "proven": now <= PROOF_RATIO * then}


def proof_text(shown):
    if shown["after"] is None:
        return "%d of %d runs since" % (shown["runs"], shown["need"])
    return "CPU-s a run %s → %s (×%.2f, %d runs) · %s" % (
        fmt(shown["before"]), fmt(shown["after"]), shown["after"] / shown["before"], shown["runs"],
        "proven" if shown["proven"] else "not proven")


def fmt(value):
    return "%.0f" % value if value >= 10 else "%.1f" % value


def problem(c, why, at_once, since, at):
    fact = "%s · %s · %.1f wall-min/day · %.1f CPU-min/day · %s CPU-s a run · audit due: %s" % (
        c["label"], c["repo"], c["wall_min_day"], c["cpu_min_day"], fmt(c["p50"]), why)
    return {"id": "%s:%s:%s" % (RULE, c["repo"], c["label"]), "rule": RULE, "state": "watch", "fact": fact,
            "value": c["wall_min_day"], "limit": None, "unit": "wall-min/day", "window_h": WINDOW_D * 24, "exposure": 0,
            "count": c["runs"], "first_seen": at, "last_seen": at, "evidence": [], "ledger": None, "group": GROUP,
            "suite": {"component": c["key"], "repo": c["repo"], "label": c["label"], "sources": c["sources"],
                      "cpu_min_day": c["cpu_min_day"], "wall_min_day": c["wall_min_day"], "p50": c["p50"],
                      "runs": c["runs"], "due": why,
                      "at_once": at_once, "since": since, "commit": c.get("commit")}}


def collect(now, journal, root, dead=None):
    """The `suites` section: suites priced, problems (one per due audit), the night's queue (`selection`, by
    wall-min/day), audit proofs and menu lines. `dead` ({repo/label: {reason, since, top, path}}, share/
    test_health.py) queues those suites too, a run or none. No journal row in the window reads nodata."""
    lo = now - WINDOW_D * 86400
    rows = runs(journal, lo)
    out = {"status": "nodata", "as_of_s": int(now), "problems": [], "selection": [], "issues": [], "proofs": {},
           "menu": [], "head": "no suite run in run-suites' journal over %d days" % WINDOW_D}
    found = price(rows, suites(repos()))
    dead = dead or {}
    found += [unrun(key, d) for key, d in sorted(dead.items()) if key not in {c["key"] for c in found}]
    if not found:
        return out
    ledger = spend.load_ledger(root)
    median = statistics.median([c["p50"] for c in found if c["runs"]] or [0.0])
    at = datetime.datetime.fromtimestamp(now).astimezone().isoformat(timespec="seconds")
    reasons, new = {}, {}
    for top in {c["top"] for c in found if c["p50"] > NEW_HEAVY * median}:
        new.update(adds(top, lo))
    for c in found:
        c["sources"] = sources(c["path"])
        row = ledger.get(ROW + c["key"])
        held = spend.blobs(c["sources"]) if row else {}
        held = None if held is None else {spend.repo_path(p, os.path.dirname(c["top"].rstrip("/"))): h
                                          for p, h in held.items()}
        reasons[c["key"]] = due(c, row, held, median, new, dead.get(c["key"]))
        if row and not reasons[c["key"]]:
            out["proofs"][c["key"]] = dict(proof(c, row), verdict=row.get("verdict"), audited_at=row.get("audited_at"))
    queue = sorted((c for c in found if reasons[c["key"]]), key=lambda c: (-c["wall_min_day"], c["key"]))
    out["problems"] = [problem(c, *reasons[c["key"]], at) for c in queue]
    out["selection"] = [p["id"] for p in out["problems"]]
    out["issues"] = [[c["wall_min_day"], c["key"]] for c in queue[:3]]
    total, cpu = sum(c["wall_min_day"] for c in found), sum(c["cpu_min_day"] for c in found)
    workers = sum(c["wall_p50"] for c in found for h in c["history"] if h["worker"])
    out.update(status="watch" if queue else "ok", cpu_min_day=round(cpu, 1), wall_min_day=round(total, 1),
               components=[{k: c[k] for k in ("key", "wall_min_day", "cpu_min_day", "p50", "runs")} for c in found],
               head="%d due · %.0f wall-min/day, %.0f CPU-min/day over %d suites · workers %d %%%s" % (
                   len(queue), total, cpu, len(found), round(100 * workers / (total * WINDOW_D * 60)) if total else 0,
                   " · next: " + queue[0]["key"] if queue else ""))
    out["menu"] = lines(found, ledger, reasons, out["proofs"])
    return out


def lines(found, ledger, reasons, proofs):
    out = []
    for c in found[:SHOWN]:
        why, row = reasons[c["key"]], ledger.get(ROW + c["key"])
        tail = "audit due: " + why[0] if why else "%s %s · %s" % (row.get("verdict"), str(row.get("audited_at"))[:10],
                                                                 proof_text(proofs[c["key"]]))
        out.append([0, "" if why else "d", False, "%6.1f wall-min/day · %5.1f CPU-min/day · %4s CPU-s a run · %s · %s" % (
            c["wall_min_day"], c["cpu_min_day"], fmt(c["p50"]), c["key"], tail)])
    rest = found[SHOWN:]
    if rest:
        out.append([0, "d", False, "%d more suites · %.1f wall-min/day · %d due" % (
            len(rest), sum(c["wall_min_day"] for c in rest), sum(1 for c in rest if reasons[c["key"]]))])
    out.append([0, "d", False, "run-suites journal · %d days" % WINDOW_D])
    return out


def restate(problems, rows):
    """A suite audited after its due reason arose is settled: a night close reruns Harness on its own branch's
    ledger."""
    out = []
    for p in problems:
        found = p.get("suite") or {}
        audited = epoch((rows.get(ROW + str(found.get("component"))) or {}).get("audited_at")) \
            if p.get("rule") == RULE else None
        if not (audited is not None and audited >= float(found.get("since") or 0)):
            out.append(p)
    return out


def record(root, journal, key, verdict, note, by, worktrees, now):
    if verdict not in spend.VERDICTS:
        raise SystemExit("verdict must be one of %s" % ", ".join(spend.VERDICTS))
    listed = suites(repos())
    found = {c["key"]: c for c in price(runs(journal, now - WINDOW_D * 86400), listed)}
    c = found.get(key) or next((unrun(key, {"top": top, "path": path}) for (repo, name), (top, path) in listed.items()
                                if "%s/%s" % (repo, os.path.splitext(name)[0]) == key), None)
    if not c:
        raise SystemExit("no suite %s in the sweep and helper repositories" % key)
    return spend.save_row(root, {
        "id": ROW + key, "title": key, "audited_at": datetime.datetime.now().astimezone().isoformat(timespec="seconds"),
        "by": by, "cpu_run": c["p50"], "cpu_min_day": c["cpu_min_day"], "wall_min_day": c["wall_min_day"],
        "sources": spend.source_blobs(root, os.path.dirname(c["top"].rstrip("/")), sources(c["path"]), worktrees),
        "verdict": verdict, "note": note})


def samples(journal, lo, hi, named=()):
    """{repo/label: [CPU-s a run]} of passing runs in [lo, hi), only the named suites when any."""
    out = {}
    for r in runs(journal, lo):
        key = "%s/%s" % (r["repo"], os.path.splitext(r["name"])[0])
        if r["end"] < hi and r["ok"] and (not named or key in named):
            out.setdefault(key, []).append(r["cpu"])
    return out
