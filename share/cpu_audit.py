"""CPU audits, beside Spend and Suite audits: every own repeating or long-lived component priced at CPU-min/day, the
median of its last 7 settled days (today alone before any), from journals the components already write: statusline
renders and background probes, the System doctor's hourly CPU of own processes, doctor collector runs, hook runs.
Wasted is the CPU of runs whose output equalled the previous run's (the statusline journals' same column). Due when
never audited, a source has another blob than at audit that a Speed audit run did not land (spend.moved), or
CPU a run reached spend.SHARE_RISE x the audit's (more runs are load, not the component); never under FLOOR_MIN_DAY CPU-min/day, whatever the reason, and
the head counts the rows that floor skipped. Rows live in Spend's ledger as `cpu:<component>`."""

import datetime
import glob
import os
import statistics

import spend

RULE = "cpu_audit"
GROUP = "CPU audits"
ROW = "cpu:"
WINDOW_D = 7
SHOWN = 10
FLOOR_MIN_DAY = 1.0
STATUSLINE = "llm-legs/bin/statusline.sh"
PROBE_SOURCES = {"work": ("llm-legs/bin/statusline-work-probe.sh", "llm-legs/share/statusline-probe.sh"),
                 "ports": ("llm-legs/bin/statusline-ports-probe.sh", "llm-legs/share/statusline-probe.sh")}
APP_SOURCES = {"Hammerspoon": ("hammerspoon/init.lua",), "hs": ("hammerspoon/init.lua",)}


def system_dir():
    """A fixture Harness directory with no SYSTEM_DOCTOR_DIR of its own never reads the live hours."""
    if os.environ.get("HARNESS_DOCTOR_DIR") and not os.environ.get("SYSTEM_DOCTOR_DIR"):
        return None
    return os.environ.get("SYSTEM_DOCTOR_DIR") or os.path.join(os.path.expanduser("~"), ".cache", "system-doctor")


def cpu_s(text, scale):
    try:
        return float(text) / scale
    except (TypeError, ValueError):
        return 0.0


def render_line(line):
    f = line.rstrip("\n").split("\t") + [None]
    return [("statusline/render", cpu_s(f[3], 1000), f[4])] if len(f) >= 5 else []


def probe_line(line):
    f = line.rstrip("\n").split("\t") + [None]
    return [("statusline/" + f[3], cpu_s(f[2], 1000), f[4])] if len(f) >= 5 and f[3] else []


def hour_line(line):
    row = spend.jsonl_row(line)
    if row is None:
        return []
    return [("process/" + str(e[0]), cpu_s(e[1], 1), None) for e in row.get("cpu_own") or row.get("cpu_top") or ()
            if isinstance(e, list) and len(e) >= 4 and e[3] == "own"]


def add(found, key, cpu, same):
    t = found.setdefault(key, [0.0, 0, 0.0, 0])
    t[0], t[1] = t[0] + cpu, t[1] + 1
    if same in ("0", "1"):
        t[2], t[3] = t[2] + (cpu if same == "1" else 0.0), t[3] + 1


def hook_line(local_day):
    """The parse of a Harness hook journal line (start us, end us, key, failed, ppid, CPU us): its key carries the
    local day the run ended, since a journal file holds a UTC day."""
    days = {}

    def parse(line):
        f = line.rstrip("\n").split("\t")
        try:
            end = int(f[1]) / 1e6
            int(f[0]), f[3]
        except (IndexError, ValueError):
            return []
        minute = int(end // 60)
        day = days.get(minute) or days.setdefault(minute, local_day(end))
        cpu = f[5] if len(f) > 5 else ""
        return [(day + " hook/" + f[2].split(" ")[0], int(cpu) / 1e6 if cpu.isdigit() else 0.0, None)]
    return parse


def tally(path, parse, cache):
    """{component: [cpu_s, runs, wasted_cpu_s, judged_runs]} of one journal file's complete lines, kept in the state
    while its size and mtime hold; a file that only grew is read from the byte the last tally ended at."""
    try:
        handle = open(path, "rb")
    except OSError:
        return {}
    with handle:
        st, head = os.fstat(handle.fileno()), handle.read(64).hex()
        held = cache.get(path)
        if held and held[:2] == [st.st_size, st.st_mtime_ns]:
            return held[2]
        grown = held and len(held) == 5 and held[4] == head[:len(held[4])] and st.st_size >= held[3]
        found = {k: list(v) for k, v in held[2].items()} if grown else {}
        handle.seek(held[3] if grown else 0)
        data = handle.read()
    cut = data.rfind(b"\n") + 1
    for line in data[:cut].decode("utf-8", "replace").split("\n"):
        for key, cpu, same in parse(line):
            add(found, key, cpu, same)
    cache[path] = [st.st_size, st.st_mtime_ns, found, (held[3] if grown else 0) + cut, head]
    return found


def days(now, state, harness_dir, speed_dir, collector_rows, local_day):
    """{journal: {day: {component: tally}}} over the window: a journal's days are the ones it holds, so a component
    reads 0 on a day its journal covers and nothing on a day it never kept. Hook runs are Harness's journal files
    (hooks/ and hooks/folded/, one UTC day each), tallied by the local day a run ended."""
    cache, lo = {}, local_day(now - WINDOW_D * 86400)
    held = state.get("cpu_files") or {}
    out = {}
    journals = [("render", os.path.join(harness_dir, "statusline"), "tsv", render_line),
                ("probes", os.path.join(speed_dir, "statusline-probes"), "tsv", probe_line)]
    if system_dir():
        journals.append(("hours", os.path.join(system_dir(), "hours"), "jsonl", hour_line))
    for name, folder, ext, parse in journals:
        for path in sorted(glob.glob(os.path.join(folder, "????-??-??." + ext))):
            day = os.path.basename(path)[:10]
            if day >= lo:
                if path in held:
                    cache[path] = held[path]
                out.setdefault(name, {})[day] = tally(path, parse, cache)
    parse = hook_line(local_day)
    for path in sorted(glob.glob(os.path.join(harness_dir, "hooks", "*.tsv"))
                       + glob.glob(os.path.join(harness_dir, "hooks", "folded", "*.tsv"))):
        if path in held:
            cache[path] = held[path]
        for key, t in tally(path, parse, cache).items():
            day, _, component = key.partition(" ")
            if day >= lo:
                into = out.setdefault("hooks", {}).setdefault(day, {}).setdefault(component, [0.0, 0, 0.0, 0])
                into[:] = [a + b for a, b in zip(into, t)]
    state["cpu_files"] = cache
    for r in collector_rows:
        if isinstance(r.get("start"), (int, float)) and r.get("doctor") and local_day(r["start"]) >= lo:
            add(out.setdefault("collector", {}).setdefault(local_day(r["start"]), {}), "doctor/" + str(r["doctor"]),
                cpu_s(r.get("cpu_s"), 1), None)
    return out


def sources(key, repos):
    kind, _, name = key.partition("/")
    rel = {"statusline": PROBE_SOURCES.get(name, (STATUSLINE,)), "doctor": ("llm-legs/bin/%s-doctor" % name,),
           "hook": ("claude-setup/hooks/" + name, "llm-legs/bin/" + name)}.get(kind) or APP_SOURCES.get(name, (name,) if "/" in name else ())
    return [os.path.join(repos, r) for r in rel if os.path.isfile(os.path.join(repos, r))]


def components(journals, today, repos):
    out = []
    for by_day in journals.values():
        settled = sorted(d for d in by_day if d < today) or [today]
        for key in sorted({k for d in settled for k in by_day.get(d, {})}):
            seen = [by_day.get(d, {}).get(key, [0.0, 0, 0.0, 0]) for d in settled]
            runs, total = sum(t[1] for t in seen), sum(t[0] for t in seen)
            out.append({"key": key, "cpu_min_day": round(statistics.median(t[0] / 60 for t in seen), 1),
                        "wasted_min_day": round(statistics.median(t[2] / 60 for t in seen), 1)
                        if any(t[3] for t in seen) else None,
                        "runs_day": round(runs / len(settled)), "cpu_s_run": round(total / runs, 3) if runs else 0.0,
                        "sources": sources(key, repos)})
    return sorted(out, key=lambda c: (-c["cpu_min_day"], c["key"]))


def due(c, row, held, repos, memo):
    if not row:
        return "never audited"
    if spend.moved(row, held, repos, memo):
        return "source changed"
    then = row.get("cpu_s_run")
    if isinstance(then, (int, float)) and then > 0 and c["cpu_s_run"] >= spend.SHARE_RISE * then:
        return "CPU a run ×%.1f since audit" % (c["cpu_s_run"] / then)
    return None


def wasted(c):
    return "-" if c["wasted_min_day"] is None else "%.1f" % c["wasted_min_day"]


def machine_share(cpu_min_day):
    return round(100 * cpu_min_day / ((os.cpu_count() or 1) * 1440), 2)


def problem(c, why, at):
    fact = "%s · %.1f CPU-min/day · %s wasted · %d runs a day · %.3f CPU-s a run · audit due: %s" % (
        c["key"], c["cpu_min_day"], wasted(c), c["runs_day"], c["cpu_s_run"], why)
    return {"id": ROW + c["key"], "rule": RULE, "state": "watch", "fact": fact, "value": machine_share(c["cpu_min_day"]),
            "limit": None, "unit": "% CPU", "window_h": WINDOW_D * 24, "exposure": 0, "count": c["runs_day"],
            "first_seen": at, "last_seen": at, "evidence": [], "ledger": None, "group": GROUP,
            "cpu": dict(c, component=c["key"], due=why)}


def collect(now, state, harness_dir, speed_dir, collector_rows, root, repos, local_day):
    """The `cpu` section: components ranked by CPU-min/day, one problem per due audit, the night's queue, menu lines."""
    out = {"status": "nodata", "as_of_s": int(now), "problems": [], "selection": [], "proofs": {},
           "menu": [], "head": "no CPU journal over %d days" % WINDOW_D}
    found = components(days(now, state, harness_dir, speed_dir, collector_rows, local_day), local_day(now),
                       repos)
    if not found:
        return out
    rows = spend.load_ledger(root)
    held = spend.blobs([s for c in found if ROW + c["key"] in rows for s in c["sources"]])
    memo = spend.landing_memo(rows.get(ROW + c["key"]) for c in found)
    reasons = {c["key"]: due(c, rows.get(ROW + c["key"]), None if held is None else {
        spend.repo_path(s, repos): h for s, h in held.items() if s in c["sources"]}, repos, memo) for c in found}
    skipped = [c["key"] for c in found if reasons[c["key"]] and c["cpu_min_day"] < FLOOR_MIN_DAY]
    reasons.update(dict.fromkeys(skipped))
    at = datetime.datetime.fromtimestamp(now).astimezone().isoformat(timespec="seconds")
    out["problems"] = [problem(c, reasons[c["key"]], at) for c in found if reasons[c["key"]]]
    out["selection"] = [p["id"] for p in out["problems"]]
    out["proofs"] = {c["key"]: {"before": rows[ROW + c["key"]].get("cpu_min_day"), "after": c["cpu_min_day"],
                                "verdict": rows[ROW + c["key"]].get("verdict"),
                                "audited_at": rows[ROW + c["key"]].get("audited_at")}
                     for c in found if ROW + c["key"] in rows and not reasons[c["key"]]}
    total = sum(c["cpu_min_day"] for c in found)
    out.update(status="watch" if out["problems"] else "ok", cpu_min_day=round(total, 1),
               head="%d due%s · %.0f CPU-min/day over %d components%s" % (
                   len(out["problems"]), floor_text(len(skipped), "CPU-min/day"), total, len(found),
                   " · next: " + out["problems"][0]["cpu"]["key"] if out["problems"] else ""))
    out["menu"] = [[0, "" if reasons[c["key"]] else "d", False, "%s %6.1f CPU-min/day · %7d runs a day · %6s wasted · %s" % (
        spend.menu_name(c["key"]), c["cpu_min_day"], c["runs_day"], wasted(c), "audit due: " + reasons[c["key"]] if reasons[c["key"]] else
        proof_text(out["proofs"][c["key"]]) if c["key"] in out["proofs"] else "under the %g CPU-min/day floor" % FLOOR_MIN_DAY)]
        for c in found[:SHOWN]]
    return out


def floor_text(skipped, unit):
    return " · %d under %g %s skipped" % (skipped, FLOOR_MIN_DAY, unit) if skipped else ""


def proof_text(shown):
    if not shown:
        return "not measured since"
    before = shown.get("before")
    return "%s %s · CPU-min/day %s → %s%s" % (shown.get("verdict"), str(shown.get("audited_at"))[:10], before,
                                             shown["after"], " · proven" if isinstance(before, (int, float))
                                             and shown["after"] < before else "")


def restate(problems, rows):
    """A component audited after CPU audits measured it is settled: a night close reruns Harness on its own ledger."""
    out = []
    for p in problems:
        row = rows.get(ROW + str((p.get("cpu") or {}).get("component"))) if p.get("rule") == RULE else None
        audited, measured = spend.epoch((row or {}).get("audited_at")), spend.epoch(p.get("last_seen"))
        if not (audited and measured and audited >= measured):
            out.append(p)
    return out


def record(root, repos, state, harness_dir, speed_dir, collector_rows, key, verdict, note, zero, by, worktrees,
           now, local_day, depends_on=None, reread_by=None):
    if verdict not in spend.VERDICTS:
        raise SystemExit("verdict must be one of %s" % ", ".join(spend.VERDICTS))
    zero = spend.zero_option(zero)
    c = next((c for c in components(days(now, state, harness_dir, speed_dir, collector_rows, local_day),
                                    local_day(now), repos) if c["key"] == key), None)
    if not c:
        raise SystemExit("no CPU component %s in the journals" % key)
    return spend.save_row(root, {
        "id": ROW + key, "title": key, "audited_at": datetime.datetime.now().astimezone().isoformat(timespec="seconds"),
        "by": by, "cpu_min_day": c["cpu_min_day"], "cpu_s_run": c["cpu_s_run"], "runs_day": c["runs_day"],
        "sources": spend.source_blobs(root, repos, c["sources"], worktrees), "verdict": verdict,
        "zero": zero, "note": note, **spend.decision_fields(verdict, depends_on, reread_by)})
