"""Tool mining: the scripts models keep writing for themselves. A deterministic scan of 24 h of chat, subagent and
worker transcripts (Claude Code and codex) for ad-hoc Bash calls (python/node/perl inline scripts, heredocs, long
jq/awk pipelines), each put in the first CLUSTERS row its text matches. A cluster costs the time to write its scripts
(characters at the measured write rate) plus calls times their median exec; the writing is what a tool removes.
Clusters over the floor become Speed's `adhoc/<key>` opportunities: a new tool plus its hint, or only the hint where
`covered_by` names a tool that already does the job. Proof is adoption: after the fix lands, the cluster's calls per
1000 Bash calls.

  tool_mining.py [--to T] [--calls]   T in epoch seconds; --calls prints each matched call
"""

import argparse
import collections
import datetime
import glob
import json
import os
import re
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import time_budget  # noqa: E402

WINDOW_S = 86400
HISTORY_D = 35
BUILD_H, PAYBACK_D = 1.0, 7
FLOOR_MIN_DAY = round(60.0 * BUILD_H / PAYBACK_D, 1)
FLOOR_SESSIONS = 3
ADOPTED = 0.5
ADHOC = re.compile(r"\b(?:python3?|node|perl|ruby)\s+(?:-\w+\s+)*-(?:c|e)\b|\b(?:python3?|node)\s+(?:-\w+\s+)*-\s*<<"
                   r"|<<-?\s*['\"]?[A-Z]+")
PIPE = re.compile(r"\b(?:jq|awk)\b")
NOT_A_SCRIPT = re.compile(r"git commit[^\n]*<<|^\s*cat\s*>>?\s*\S+\s*<<|gh (?:pr|issue) (?:create|comment|edit)[^\n]*<<"
                          r"|\bworker-run\b[^\n]*<<|\breport-bus\b[^\n]*<<")
WRITES = r"(?:write_text|json\.dump\(|\.write\(|open\([^)]*['\"][wa]|\bsponge\b|>\s*\S*\.json\b)"
# (key, job, covered_by, pattern): first match wins; covered_by names the tool that already does the job.
CLUSTERS = (
    ("file-edit", "edit a file by string replace", "the Edit tool",
     r"\.replace\([\s\S]*(?:write_text|\.write\()|\bsed -i\b|\bperl -\w*i\b"),
    ("ledger-patch", "patch a doctor ledger row", "bin/doctor-fix close",
     r"(?:harness|spend|doctor|code|system|updater)-ledger\.json[\s\S]*" + WRITES),
    ("ledger-query", "read doctor ledger rows", None, r"(?:harness|spend|doctor|code|system|updater)-ledger\.json"),
    ("suite-history", "read suite run history", None, r"run-suites/(?:runs\.jsonl|times\.tsv)"),
    ("night-record", "read a night record", "bin/night-run report", r"doctors/nights|night-run|nights/\w+\.json"),
    ("doctor-state", "read a doctor's cache (latest, state, days, journals)", None,
     r"\.cache/(?:[\w-]+-doctor|doctors)\b|-doctor/(?:latest|state)\.json"),
    ("worker-runs", "read worker run history", None, r"worker-stats|runs\.jsonl|legs\.jsonl"),
    ("tokenmap", "query token-map spend", None, r"tokenmap|spend-(?:7d|24h|3d)\.json|\.sqlite3?\b"),
    ("transcript-scan", "scan chat transcripts", None,
     r"projects/[^\s'\"]*\.jsonl|\.claude/projects|tool_use|[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}"
     r"\.jsonl|rollout-[\w-]+\.jsonl"),
    ("logo-verdict", "append a judge verdict to a logo-bench verdicts.csv", None,
     r"verdicts\.csv[\s\S]*(?:open\([^)]*['\"]a|writerow|\.write\()|>>\s*\S*verdicts\.csv"),
    ("logo-bench", "read logo-bench lane results and verdicts", None,
     r"verdicts\.(?:csv|jsonl)|defects\.csv|key\.json|manifest\.json|judge-(?:answer|input)|logo-vectorizer-bench"
     r"|results/(?:lanes|ab)|tracers/|\.venv/bin/python"),
    ("review-bench", "read review-bench meta and findings", None,
     r"review-bench|findings[\w-]*\.json|panel\.log|meta\.json"),
    ("image-probe", "measure image pixels", None, r"from PIL|import numpy|import cv2|Image\.open"),
    ("settings", "inspect Claude settings", None, r"settings(?:\.local)?\.json|\.claude\.json"),
    ("limits", "inspect account limits", "llm-limits --table --no-write", r"llm-limits|limits\.json|\.claudeb/"),
    ("experiments", "read EXPERIMENTS.json", None, r"EXPERIMENTS\.json"),
    ("module-probe", "import a harness module to probe it", None,
     r"sys\.path\.(?:insert|append)|importlib|SourceFileLoader"),
    ("hook-replay", "replay a hook on a JSON payload", None, r"tool_input|hook_event_name|payloads?\.jsonl?\b"),
    ("file-read", "print part of a text file", "the Read and Grep tools",
     r"open\([^)]*\.(?:md|sh|py|lua|txt|tsv)['\"]?\)\.read\(\)|read_text\(\)\.split|\.split\(['\"]\\n['\"]\)\["),
    ("json-other", "read some other JSON", None, r"json\.load|JSON\.parse|\bjq\b"),
    ("text-other", "other text processing", None, r""),
)
CATCH_ALL = ("json-other", "text-other")
RULES = [(key, job, tool, re.compile(pattern)) for key, job, tool, pattern in CLUSTERS]
TS = re.compile(rb'"timestamp":"([0-9T:.+-]+Z?)"')
MSG = re.compile(rb'"message":\{[^{]*?"id":"(msg_\w+)"')
RESULT = re.compile(rb'"tool_use_id":"(\w+)"')
CODEX_CMD = re.compile(r"""exec_command\(\{\s*cmd:\s*("(?:[^"\\]|\\.)*")""")


def projects_dir():
    return time_budget.env_path("CLAUDE_PROJECTS_DIR", ".claude", "projects")


def codex_dir():
    return os.environ.get("CODEXB_PROFILES_DIR") or time_budget.home(".codex-profiles")


def cache_path():
    return os.path.join(os.environ.get("SPEED_DOCTOR_DIR") or time_budget.home(".cache", "speed-doctor"),
                        "tool-mining.json")


def epoch(text):
    try:
        return datetime.datetime.fromisoformat(text.replace("Z", "+00:00")).timestamp()
    except ValueError:
        return None


def adhoc(cmd):
    return bool(ADHOC.search(cmd) or cmd.count("|") >= 3 and PIPE.search(cmd) and len(cmd) > 150) \
        and not NOT_A_SCRIPT.search(cmd)


def cluster(cmd):
    return next(key for key, _, _, rule in RULES if rule.search(cmd))


def files(root, pattern, lo):
    out = []
    for path in glob.glob(os.path.join(root, pattern)):
        try:
            if os.path.getmtime(path) >= lo:
                out.append(path)
        except OSError:
            continue
    return out


def claude_calls(path, lo, hi, out, rate):
    """Ad-hoc Bash calls of one Claude Code transcript: {session, worker, ts, cmd, exec_s}. A tool_use block written
    right after another block of the same message adds (chars, seconds) to the write rate."""
    session = os.path.splitext(os.path.basename(path))[0]
    worker, pending, prev = "/subagents/" in path, {}, b""
    try:
        handle = open(path, "rb")
    except OSError:
        return
    with handle:
        for n, line in enumerate(handle):
            if n < 40 and b"RUN-TOKEN: " in line:
                worker = True
            if b'"name":"Bash"' in line and b'"tool_use"' in line:
                try:
                    record = json.loads(line)
                except ValueError:
                    prev = line
                    continue
                at = epoch(record.get("timestamp") or "")
                blocks = (record.get("message") or {}).get("content")
                for block in blocks if isinstance(blocks, list) else ():
                    if not isinstance(block, dict) or block.get("type") != "tool_use" or block.get("name") != "Bash":
                        continue
                    cmd = str((block.get("input") or {}).get("command") or "")
                    same = MSG.search(prev)
                    if same and same.group(1) == ((record.get("message") or {}).get("id") or "").encode():
                        before = TS.search(prev)
                        start = epoch(before.group(1).decode()) if before else None
                        if at and start and 0 < at - start < 600:
                            rate[0] += len(cmd)
                            rate[1] += at - start
                    if at and lo <= at < hi:
                        rate[2] += 1
                        if adhoc(cmd):
                            call = {"session": session, "worker": worker, "ts": at, "cmd": cmd, "exec_s": 0.0}
                            pending[block.get("id")] = call
                            out.append(call)
            elif pending and b'"tool_use_id"' in line:
                for found in RESULT.finditer(line):
                    call = pending.pop(found.group(1).decode(), None)
                    stamp = TS.search(line)
                    end = epoch(stamp.group(1).decode()) if stamp else None
                    if call and end and end >= call["ts"]:
                        call["exec_s"] = end - call["ts"]
            prev = line


def codex_calls(path, lo, hi, out, rate):
    """Ad-hoc commands of one codex rollout's exec calls; codex runs only as a worker."""
    session = os.path.basename(path)[-42:-6]
    pending = {}
    try:
        handle = open(path, "rb")
    except OSError:
        return
    with handle:
        for line in handle:
            if b'"custom_tool_call"' in line and b"exec_command" in line:
                try:
                    record = json.loads(line)
                except ValueError:
                    continue
                at = epoch(record.get("timestamp") or "")
                payload = record.get("payload") or {}
                if not at or not lo <= at < hi:
                    continue
                literals = CODEX_CMD.findall(str(payload.get("input") or ""))
                for literal in literals:
                    try:
                        cmd = json.loads(literal.replace("\\'", "'"))
                    except ValueError:
                        continue
                    rate[2] += 1
                    if adhoc(cmd):
                        call = {"session": session, "worker": True, "ts": at, "cmd": cmd, "exec_s": 0.0,
                                "share": 1.0 / len(literals)}
                        pending.setdefault(payload.get("call_id"), []).append(call)
                        out.append(call)
            elif pending and b'"custom_tool_call_output"' in line:
                try:
                    record = json.loads(line)
                except ValueError:
                    continue
                end = epoch(record.get("timestamp") or "")
                for call in pending.pop((record.get("payload") or {}).get("call_id"), ()):
                    if end and end >= call["ts"]:
                        call["exec_s"] = (end - call["ts"]) * call.pop("share")


def scan(lo, hi):
    """(ad-hoc calls in [lo, hi), all Bash calls in it, write rate in chars a second or None)."""
    calls, rate = [], [0, 0.0, 0]
    for path in files(projects_dir(), "*/*.jsonl", lo) + files(projects_dir(), "*/*/subagents/*.jsonl", lo):
        claude_calls(path, lo, hi, calls, rate)
    for path in files(codex_dir(), "*/sessions/*/*/*/rollout-*.jsonl", lo):
        codex_calls(path, lo, hi, calls, rate)
    return calls, rate[2], (rate[0] / rate[1] if rate[1] else None)


def day_of(calls, bash, chars_s, hi):
    """One scanned window's numbers per cluster: calls, sessions, minutes (the scripts' writing plus calls times the
    median exec, as an edit and its suite run often share one call), worker minutes, the writing part, two examples."""
    out = {"bash_calls": bash, "chars_s": round(chars_s, 1) if chars_s else None, "to_s": int(hi), "clusters": {}}
    grouped = collections.defaultdict(list)
    for call in calls:
        grouped[cluster(call["cmd"])].append(call)
    for key, group in grouped.items():
        median = sorted(c["exec_s"] for c in group)[len(group) // 2]
        write = [len(c["cmd"]) / chars_s / 60.0 if chars_s else 0.0 for c in group]
        worker = [w + median / 60.0 for w, c in zip(write, group) if c["worker"]]
        shown = sorted((c["cmd"] for c in group if len(c["cmd"]) >= 40), key=len)[:2]
        out["clusters"][key] = {"calls": len(group), "sessions": len({c["session"] for c in group}),
                                "min": round(sum(write) + len(group) * median / 60.0, 2),
                                "worker_min": round(sum(worker), 2), "write_min": round(sum(write), 2),
                                "examples": [" ⏎ ".join(c.splitlines())[:200] for c in shown]}
    return out


def per_1k(day, key):
    return 1000.0 * ((day["clusters"].get(key) or {}).get("calls") or 0) / max(1, day["bash_calls"])


def adoption(history, key, landed):
    """A landed fix's cluster in calls per 1000 Bash calls, the scanned days before its landing against the days
    after: proven once after is at most ADOPTED times before."""
    before = [per_1k(d, key) for d in history.values() if d["to_s"] <= landed]
    after = [per_1k(d, key) for d in history.values() if d["to_s"] - WINDOW_S >= landed]
    b = round(sum(before) / len(before), 1) if before else None
    a = round(sum(after) / len(after), 1) if after else None
    state = "pending" if b is None or a is None else "proven" if a <= ADOPTED * b else "not adopted"
    return {"state": state, "before": b, "after": a}


def findings(day, history, since=lambda target: None):
    """({target: adoption} of every cluster whose fix landed, the clusters over the floor worst writing minutes
    first); a landed cluster is charged only on a window that began after its landing."""
    out, adopted = [], {}
    recent = [d for k, d in sorted(history.items())[-7:]]
    for key, job, tool, _ in RULES:
        target = "adhoc/" + key
        landed = since(target)
        if landed:
            adopted[target] = adoption(history, key, landed)
        c = day["clusters"].get(key)
        if not c or key in CATCH_ALL or landed and day["to_s"] - WINDOW_S < landed:
            continue
        if c["write_min"] >= FLOOR_MIN_DAY and c["sessions"] >= FLOOR_SESSIONS:
            out.append({"key": key, "target": target, "job": job, "covered_by": tool, "calls": c["calls"],
                        "sessions": c["sessions"], "min_day": c["min"], "worker_min_day": c["worker_min"],
                        "write_min_day": c["write_min"], "per_1k": round(per_1k(day, key), 1),
                        "days": sum(1 for d in recent if key in d["clusters"]), "examples": c["examples"],
                        **({"adoption": adopted[target]} if target in adopted else {})})
    return adopted, sorted(out, key=lambda f: (-f["write_min_day"], f["key"]))


def collect(now, write=False, since=lambda target: None):
    """The `adhoc` section: the scan of the local day before `now`'s, done once a local day (the first Speed run after
    midnight, before the night starts), the per-day history, the findings, adoption and the scan's own seconds."""
    started = time.monotonic()
    cache = time_budget.read_json(cache_path(), {})
    history = (cache.get("history") if isinstance(cache, dict) else None) or {}
    hi = time_budget.day_bounds(time_budget.local_day(now))[0]
    day = time_budget.local_day(hi - 1)
    scan_s = cache.get("scan_s") if isinstance(cache, dict) else None
    if day not in history:
        calls, bash, chars_s = scan(hi - WINDOW_S, hi)
        history[day] = day_of(calls, bash, chars_s, hi)
        scan_s = round(time.monotonic() - started, 2)
        history = {d: v for d, v in history.items() if d >= time_budget.local_day(hi - HISTORY_D * 86400)}
        if write:
            time_budget.write_json(cache_path(), {"history": history, "scan_s": scan_s})
    adopted, found = findings(history[day], history, since)
    return {"day": day, "scan_s": scan_s, "bash_calls": history[day]["bash_calls"], "chars_s": history[day]["chars_s"],
            "floor_min_day": FLOOR_MIN_DAY, "findings": found, "adoption": adopted}


def main(argv):
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    parser.add_argument("--to", type=float, default=None)
    parser.add_argument("--calls", action="store_true")
    args = parser.parse_args(argv)
    hi = args.to or time.time()
    started = time.monotonic()
    calls, bash, chars_s = scan(hi - WINDOW_S, hi)
    if args.calls:
        for call in calls:
            print(json.dumps(dict(call, cluster=cluster(call["cmd"])), ensure_ascii=False))
        return 0
    day = day_of(calls, bash, chars_s, hi)
    print("%d Bash calls, %d ad hoc, write rate %s chars/s, scan %.1f s" % (
        bash, len(calls), round(chars_s or 0, 1), time.monotonic() - started))
    for key, c in sorted(day["clusters"].items(), key=lambda kv: -kv[1]["write_min"]):
        print("%-16s %5d calls %4d sessions %6.1f min/day (%5.1f writing, %5.1f worker)" % (
            key, c["calls"], c["sessions"], c["min"], c["write_min"], c["worker_min"]))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
