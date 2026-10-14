"""Tool mining: the scripts models keep writing for themselves. A deterministic scan of 24 h of chat, subagent and
worker transcripts (Claude Code and codex) for ad-hoc Bash calls (python/node/perl inline scripts, heredocs, long
jq/awk pipelines), each put in the first CLUSTERS row its text matches. A cluster costs the time to write its scripts
(characters at the measured write rate) plus calls times their median exec; the writing is what a tool removes.
Clusters over the floor become Speed's `adhoc/<key>` opportunities: a new tool plus its hint, or only the hint where
`covered_by` names a tool that already does the job. Proof is net (`net`): the job's whole cost per 1000 Bash calls,
minutes and Opus-eq tokens, before the fix against after: the cluster's residual calls, substitutes (ad-hoc calls an
earlier cluster took that match this one's pattern), the tool's own calls (its bench's `command`) and the hint's
always-loaded bytes once a session. A fix lands only with a bench (`bench_faults`).

  tool_mining.py [--to T] [--calls]   T in epoch seconds; --calls prints each matched call
"""

import argparse
import collections
import datetime
import glob
import json
import os
import re
import statistics
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import chat_names  # noqa: E402
import time_budget  # noqa: E402

WINDOW_S = 86400
HISTORY_D = 35
BUILD_H, PAYBACK_D = 1.0, 7
FLOOR_MIN_DAY = round(60.0 * BUILD_H / PAYBACK_D, 1)
FLOOR_SESSIONS = 3
NET_DAYS = 7
OUTPUT_EQ, CHARS_PER_TOKEN = 5.0, 3.2
BENCH = ("command", "hint_b", "calls", "adhoc_wall_s", "adhoc_out_b", "tool_wall_s", "tool_out_b")
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


def projects_roots():
    """CLAUDE_PROJECTS_DIR alone where set (a fixture), else every Claude transcript root: claudeb profiles' too."""
    if os.environ.get("CLAUDE_PROJECTS_DIR"):
        return [projects_dir()]
    return [str(root) for root in chat_names.transcript_roots()]


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


def text_b(content):
    if isinstance(content, str):
        return len(content.encode())
    return sum(text_b(c.get("text", c.get("content"))) for c in content if isinstance(c, dict)) \
        if isinstance(content, list) else 0


def kept(cmd, tools, at, session, worker, out):
    """The call of a benched tool (`tool`: its target) or an ad-hoc call, appended to `out`; None for any other."""
    tool = next((target for target, rule in tools.items() if rule.search(cmd)), None)
    if not tool and not adhoc(cmd):
        return None
    call = {"session": session, "worker": worker, "ts": at, "cmd": cmd, "exec_s": 0.0, "out_b": 0}
    if tool:
        call["tool"] = tool
    out.append(call)
    return call


def claude_calls(path, lo, hi, out, rate, tools=None):
    """Ad-hoc and benched-tool Bash calls of one Claude Code transcript: {session, worker, ts, cmd, exec_s, out_b}. A
    tool_use block written right after another block of the same message adds (chars, seconds) to the write rate."""
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
                        rate[3].add(session)
                        call = kept(cmd, tools or {}, at, session, worker, out)
                        if call:
                            pending[block.get("id")] = call
            elif pending and b'"tool_use_id"' in line:
                ids = [i for i in (f.group(1).decode() for f in RESULT.finditer(line)) if i in pending]
                if not ids:
                    prev = line
                    continue
                stamp = TS.search(line)
                end = epoch(stamp.group(1).decode()) if stamp else None
                try:
                    blocks = (json.loads(line).get("message") or {}).get("content")
                except (ValueError, AttributeError):
                    blocks = None
                sizes = {b.get("tool_use_id"): text_b(b.get("content")) for b in blocks if isinstance(b, dict)} \
                    if isinstance(blocks, list) else {}
                for ident in ids:
                    call = pending.pop(ident)
                    call["out_b"] = sizes.get(ident, 0)
                    if end and end >= call["ts"]:
                        call["exec_s"] = end - call["ts"]
            prev = line


def codex_calls(path, lo, hi, out, rate, tools=None):
    """Ad-hoc and benched-tool commands of one codex rollout's exec calls; codex runs only as a worker."""
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
                    rate[3].add(session)
                    call = kept(cmd, tools or {}, at, session, True, out)
                    if call:
                        call["share"] = 1.0 / len(literals)
                        pending.setdefault(payload.get("call_id"), []).append(call)
            elif pending and b'"custom_tool_call_output"' in line:
                try:
                    record = json.loads(line)
                except ValueError:
                    continue
                end = epoch(record.get("timestamp") or "")
                payload = record.get("payload") or {}
                for call in pending.pop(payload.get("call_id"), ()):
                    share = call.pop("share")
                    call["out_b"] = round(text_b(payload.get("output")) * share)
                    if end and end >= call["ts"]:
                        call["exec_s"] = (end - call["ts"]) * share


def scan(lo, hi, tools=None):
    """(ad-hoc and benched-tool calls in [lo, hi), all Bash calls in it, write rate in chars a second or None, the
    sessions that made a Bash call); `tools` maps a target to the pattern of its tool's calls."""
    calls, rate = [], [0, 0.0, 0, set()]
    for root in projects_roots():
        for path in files(root, "*/*.jsonl", lo) + files(root, "*/*/subagents/*.jsonl", lo):
            claude_calls(path, lo, hi, calls, rate, tools)
    for path in files(codex_dir(), "*/sessions/*/*/*/rollout-*.jsonl", lo):
        codex_calls(path, lo, hi, calls, rate, tools)
    return calls, rate[2], (rate[0] / rate[1] if rate[1] else None), len(rate[3])


def part(group):
    return {"calls": len(group), "chars": sum(len(c["cmd"]) for c in group),
            "exec_s": round(sorted(c["exec_s"] for c in group)[len(group) // 2], 2) if group else 0.0,
            "out_b": sum(c.get("out_b") or 0 for c in group)}


def day_of(calls, bash, chars_s, hi, sessions=0):
    """One scanned window's numbers per cluster: calls, sessions, minutes (the scripts' writing plus calls times the
    median exec, as an edit and its suite run often share one call), worker minutes, the writing part, two examples,
    characters and output bytes; per cluster its substitutes (`shadow`: ad-hoc calls an earlier cluster took that
    match its pattern) and per benched target its tool's calls (`tools`)."""
    out = {"bash_calls": bash, "chars_s": round(chars_s, 1) if chars_s else None, "to_s": int(hi), "clusters": {},
           "sessions": sessions, "shadow": {}, "tools": {}}
    grouped, shadow, tools = (collections.defaultdict(list) for _ in range(3))
    order = [key for key, _, _, _ in RULES]
    for call in calls:
        if call.get("tool"):
            tools[call["tool"]].append(call)
            continue
        own = cluster(call["cmd"])
        grouped[own].append(call)
        for key, _, _, rule in RULES[order.index(own) + 1:]:
            if key not in CATCH_ALL and rule.search(call["cmd"]):
                shadow[key].append(call)
    for key, group in grouped.items():
        median = sorted(c["exec_s"] for c in group)[len(group) // 2]
        write = [len(c["cmd"]) / chars_s / 60.0 if chars_s else 0.0 for c in group]
        worker = [w + median / 60.0 for w, c in zip(write, group) if c["worker"]]
        shown = sorted((c["cmd"] for c in group if len(c["cmd"]) >= 40), key=len)[:2]
        out["clusters"][key] = dict(part(group), sessions=len({c["session"] for c in group}),
                                    min=round(sum(write) + len(group) * median / 60.0, 2),
                                    worker_min=round(sum(worker), 2), write_min=round(sum(write), 2),
                                    examples=[" ⏎ ".join(c.splitlines())[:200] for c in shown])
    out["shadow"] = {key: part(group) for key, group in shadow.items()}
    out["tools"] = {target: part(group) for target, group in tools.items()}
    return out


def per_1k(day, key):
    return 1000.0 * ((day["clusters"].get(key) or {}).get("calls") or 0) / max(1, day["bash_calls"])


def job_cost(d, key, hint_b):
    """(writing min, exec min, Opus-eq tokens) per 1000 Bash calls of the job on one scanned day: the cluster's
    residual calls, its substitutes and its tool's calls (characters written, calls times median exec, output read)
    plus the hint's bytes once a session."""
    parts = [d["clusters"].get(key) or {}, d["shadow"].get(key) or {}, d["tools"].get("adhoc/" + key) or {}]
    chars = sum(p.get("chars") or 0 for p in parts)
    scale = 1000.0 / max(1, d["bash_calls"])
    return (scale * chars / d["chars_s"] / 60.0, scale * sum((p.get("calls") or 0) * (p.get("exec_s") or 0.0)
                                                             for p in parts) / 60.0,
            scale * (OUTPUT_EQ * chars + sum(p.get("out_b") or 0 for p in parts) + hint_b * d["sessions"])
            / CHARS_PER_TOKEN)


def load_factor(before, after, key):
    """How much slower the machine ran the other clusters' calls after the landing: the median over the clusters
    seen on both sides of their mean median exec after over before, 1 under time_budget's LOAD_CONTROLS of them."""
    ratios = []
    for other in sorted({k for d in after for k in d["clusters"]} - {key}):
        sides = [[d["clusters"][other]["exec_s"] for d in side if other in d["clusters"]] for side in (before, after)]
        if all(sides) and sum(sides[0]) > 0:
            ratios.append(sum(sides[1]) / len(sides[1]) / (sum(sides[0]) / len(sides[0])))
    return statistics.median(ratios) if len(ratios) >= time_budget.LOAD_CONTROLS else 1.0


def net(history, key, landed, bench=None):
    """A landed fix's job cost, its last NET_DAYS scanned days before the landing against its last NET_DAYS after,
    per 1000 Bash calls, after's exec over the load factor, priced at the newest day's Bash calls: proven when the
    minutes and the tokens both fell, worse when either rose."""
    days = sorted((d for d in history.values() if "shadow" in d and d.get("chars_s")), key=lambda d: d["to_s"])
    before = [d for d in days if d["to_s"] <= landed][-NET_DAYS:]
    after = [d for d in days if d["to_s"] - WINDOW_S >= landed][-NET_DAYS:]
    if not before or not after:
        return {"state": "pending", "days": [len(before), len(after)]}
    hint = (bench or {}).get("hint_b") or 0
    (bw, be, bt), (aw, ae, at) = ([sum(x) / len(side) for x in zip(*(job_cost(d, key, h) for d in side))]
                                  for side, h in ((before, 0), (after, hint)))
    factor = load_factor(before, after, key)
    was, now, volume = bw + be, aw + ae / factor, after[-1]["bash_calls"] / 1000.0
    state = "proven" if now < was and at < bt else "worse" if now > was or at > bt else "even"
    return {"state": state, "days": [len(before), len(after)], "min_before": round(was * volume, 2),
            "min_after": round(now * volume, 2), "saved_min_day": round((was - now) * volume, 2),
            "tok_before": round(bt * volume), "tok_after": round(at * volume),
            "cost": round(at / bt, 2) if bt else None, "load": round(factor, 2)}


def number(value):
    return isinstance(value, (int, float)) and not isinstance(value, bool) and value >= 0


def bench_faults(bench, hint_only=False):
    """Why an adhoc fix's bench keeps it from landing, [] when it lands. The bench runs the cluster's own example
    calls (`calls` names them and their inputs) and the tool on the same inputs: the tool's wall and output bytes at
    most the ad-hoc median's, a longer output only with a `reason`; `command` matches the tool's Bash calls (empty
    only on a hint row whose tool is no Bash command), `hint_b` the hint's bytes loaded in every session."""
    if not isinstance(bench, dict):
        return ["no bench {%s}" % ", ".join(BENCH)]
    missing = [k for k in BENCH if k not in bench]
    if missing:
        return ["the bench lacks " + ", ".join(missing)]
    out = ["bench %s is no number >= 0" % k for k in BENCH[1:2] + BENCH[3:] if not number(bench[k])]
    if not str(bench["calls"] or "").strip():
        out.append("the bench names no example calls and inputs")
    command = bench["command"]
    if not isinstance(command, str) or not command and not hint_only:
        out.append("the bench names no command matching the tool's Bash calls")
    else:
        try:
            re.compile(command)
        except re.error as exc:
            out.append("the bench command is no pattern: %s" % exc)
    if out:
        return out
    if bench["tool_wall_s"] > bench["adhoc_wall_s"]:
        out.append("the tool's wall %s s is over the ad-hoc median's %s s" % (bench["tool_wall_s"], bench["adhoc_wall_s"]))
    if bench["tool_out_b"] > bench["adhoc_out_b"] and not str(bench.get("reason") or "").strip():
        out.append("the tool prints %s bytes, over the ad-hoc median's %s, with no reason"
                   % (bench["tool_out_b"], bench["adhoc_out_b"]))
    return out


def ledger_faults(ledger):
    """`(row id, index, fault)` of every fix on an `adhoc/<key>` opportunity row whose bench keeps it from landing."""
    covered = {key: tool for key, _, tool, _ in RULES}
    faults = []
    for row in (ledger.get("rows") if isinstance(ledger, dict) else None) or ():
        match = (row.get("match") or {}) if isinstance(row, dict) else {}
        ident = str(match.get("ident") or "")
        if match.get("rule") != "opportunity" or not ident.startswith("adhoc/"):
            continue
        for index, fix in enumerate(row.get("fixes") or ()):
            for fault in bench_faults((fix or {}).get("bench") if isinstance(fix, dict) else None,
                                      bool(covered.get(ident[6:]))):
                faults.append((row.get("id") or "?", index, fault))
    return faults


def findings(day, history, since=lambda target: None, bench=lambda target: None):
    """({target: net} of every cluster whose fix landed, the clusters over the floor worst writing minutes first); a
    landed cluster is charged only on a window that began after its landing."""
    out, nets = [], {}
    recent = [d for k, d in sorted(history.items())[-7:]]
    for key, job, tool, _ in RULES:
        target = "adhoc/" + key
        landed = since(target)
        if landed:
            nets[target] = net(history, key, landed, bench(target))
        c = day["clusters"].get(key)
        if not c or key in CATCH_ALL or landed and day["to_s"] - WINDOW_S < landed:
            continue
        if c["write_min"] >= FLOOR_MIN_DAY and c["sessions"] >= FLOOR_SESSIONS:
            out.append({"key": key, "target": target, "job": job, "covered_by": tool, "calls": c["calls"],
                        "sessions": c["sessions"], "min_day": c["min"], "worker_min_day": c["worker_min"],
                        "write_min_day": c["write_min"], "per_1k": round(per_1k(day, key), 1),
                        "days": sum(1 for d in recent if key in d["clusters"]), "examples": c["examples"],
                        **({"net": nets[target]} if target in nets else {})})
    return nets, sorted(out, key=lambda f: (-f["write_min_day"], f["key"]))


def tool_rules(bench):
    out = {}
    for key, _, _, _ in RULES:
        command = (bench("adhoc/" + key) or {}).get("command")
        try:
            if command and isinstance(command, str):
                out["adhoc/" + key] = re.compile(command)
        except re.error:
            continue
    return out


def collect(now, write=False, since=lambda target: None, bench=lambda target: None):
    """The `adhoc` section: the scan of the local day before `now`'s, done once a local day (the first Speed run after
    midnight, before the night starts), the per-day history, the findings, each landed fix's net and the scan's own
    seconds; `bench` gives a target's last fix bench, whose command marks its tool's calls."""
    started = time.monotonic()
    cache = time_budget.read_json(cache_path(), {})
    history = (cache.get("history") if isinstance(cache, dict) else None) or {}
    hi = time_budget.day_bounds(time_budget.local_day(now))[0]
    day = time_budget.local_day(hi - 1)
    scan_s = cache.get("scan_s") if isinstance(cache, dict) else None
    if "shadow" not in (history.get(day) or {}):
        calls, bash, chars_s, sessions = scan(hi - WINDOW_S, hi, tool_rules(bench))
        history[day] = day_of(calls, bash, chars_s, hi, sessions)
        scan_s = round(time.monotonic() - started, 2)
        history = {d: v for d, v in history.items() if d >= time_budget.local_day(hi - HISTORY_D * 86400)}
        if write:
            time_budget.write_json(cache_path(), {"history": history, "scan_s": scan_s})
    nets, found = findings(history[day], history, since, bench)
    return {"day": day, "scan_s": scan_s, "bash_calls": history[day]["bash_calls"], "chars_s": history[day]["chars_s"],
            "floor_min_day": FLOOR_MIN_DAY, "findings": found, "net": nets}


def main(argv):
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    parser.add_argument("--to", type=float, default=None)
    parser.add_argument("--calls", action="store_true")
    args = parser.parse_args(argv)
    hi = args.to or time.time()
    started = time.monotonic()
    calls, bash, chars_s, sessions = scan(hi - WINDOW_S, hi)
    if args.calls:
        for call in calls:
            print(json.dumps(dict(call, cluster=cluster(call["cmd"])), ensure_ascii=False))
        return 0
    day = day_of(calls, bash, chars_s, hi, sessions)
    print("%d Bash calls, %d ad hoc, write rate %s chars/s, scan %.1f s" % (
        bash, len(calls), round(chars_s or 0, 1), time.monotonic() - started))
    for key, c in sorted(day["clusters"].items(), key=lambda kv: -kv[1]["write_min"]):
        print("%-16s %5d calls %4d sessions %6.1f min/day (%5.1f writing, %5.1f worker)" % (
            key, c["calls"], c["sessions"], c["min"], c["write_min"], c["worker_min"]))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
