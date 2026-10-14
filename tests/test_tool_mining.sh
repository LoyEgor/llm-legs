#!/usr/bin/env bash
. "${BASH_SOURCE%"${BASH_SOURCE##*/}"}lib/suite-journal.sh"
# share/tool_mining.py off fixture transcripts (a chat, a RUN-TOKEN worker, a subagent, a codex rollout): which Bash
# calls are ad hoc, their clusters, exec, writing time and output, substitutes, a benched tool's calls, the floor, the
# once-a-day cache, a landed fix's net (proven, worse, load-matched, drift), the bench gate, Speed's adhoc opportunities
# and regressions and Harness's net proof. Fixture directories only.
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

asserts=$(python3 - "$ROOT" "$WORK" <<'EOF'
import importlib.machinery, importlib.util, json, os, sys, time

root, work = sys.argv[1], sys.argv[2]
count = [0]


def check(cond, what):
    count[0] += 1
    if not cond:
        print("FAIL: %s" % what, file=sys.stderr)
        sys.exit(1)


projects, codex = os.path.join(work, "projects"), os.path.join(work, "codex")
os.environ.update({"HOME": os.path.join(work, "home"), "CLAUDE_PROJECTS_DIR": projects, "CODEXB_PROFILES_DIR": codex,
                   "SPEED_DOCTOR_DIR": os.path.join(work, "speed"), "HARNESS_DOCTOR_DIR": os.path.join(work, "harness")})
sys.path.insert(0, os.path.join(root, "share"))
import tool_mining as t  # noqa: E402

NOW = time.mktime(time.strptime(time.strftime("%Y-%m-%d") + " 12:00", "%Y-%m-%d %H:%M"))
HI = t.time_budget.day_bounds(t.time_budget.local_day(NOW))[0]
iso = lambda at: time.strftime("%Y-%m-%dT%H:%M:%S", time.gmtime(at)) + ".000Z"
QUERY = "python3 - <<'EOF'\nimport json\nprint(json.load(open('share/harness-ledger.json'))['rows'][0])\nEOF"
EDIT = "python3 - <<'EOF'\ns=open('a.sh').read()\ns=s.replace('x',\n'y')\nopen('a.sh','w').write(s)\nEOF"
COMMIT = "git commit -qm \"$(cat <<'EOF'\nmsg\nEOF\n)\""


def bash(at, cmd, msg, ident):
    return {"type": "assistant", "timestamp": iso(at), "message": {"id": msg, "content": [
        {"type": "tool_use", "id": ident, "name": "Bash", "input": {"command": cmd}}]}}


def result(at, ident):
    return {"type": "user", "timestamp": iso(at), "message": {"content": [
        {"type": "tool_result", "tool_use_id": ident, "content": "ok"}]}}


def transcript(path, rows):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w") as handle:
        handle.write("".join(json.dumps(r, separators=(",", ":")) + "\n" for r in rows))


T0 = HI - 6 * 3600
transcript(os.path.join(projects, "-p", "chat1.jsonl"), [
    {"type": "user", "timestamp": iso(T0 - 5), "message": {"content": "look at the ledger"}},
    {"type": "assistant", "timestamp": iso(T0), "message": {"id": "msg_A", "content": [{"type": "thinking"}]}},
    bash(T0 + 2, QUERY, "msg_A", "toolu_q1"), result(T0 + 3, "toolu_q1"),
    bash(T0 + 10, "ls -la", "msg_B", "toolu_ls"), result(T0 + 11, "toolu_ls"),
    bash(T0 + 20, COMMIT, "msg_C", "toolu_c"), result(T0 + 21, "toolu_c"),
    bash(T0 + 30, EDIT, "msg_D", "toolu_e"), result(T0 + 60, "toolu_e"),
    bash(HI - 2 * 86400, QUERY, "msg_E", "toolu_old"), result(HI - 2 * 86400 + 1, "toolu_old")])
transcript(os.path.join(projects, "-p", "w1.jsonl"), [
    {"type": "user", "timestamp": iso(T0), "message": {"content": "do it\n\nRUN-TOKEN: claudeb-1-2-ab"}},
    bash(T0 + 5, QUERY, "msg_W", "toolu_w1"), result(T0 + 8, "toolu_w1"),
    bash(T0 + 15, "bin/ledger-rows harness 0", "msg_W2", "toolu_w2"), result(T0 + 16, "toolu_w2")])
transcript(os.path.join(projects, "-p", "chat1", "subagents", "agent-1.jsonl"), [
    bash(T0 + 7, QUERY, "msg_S", "toolu_s1"), result(T0 + 12, "toolu_s1")])
verdict = "python3 - <<'PY'\nwith open('results/ab-judge/x/verdicts.csv','a') as f:\n f.write('p1,A,1\\n')\nPY"
js = "text(await tools.exec_command({cmd:%s}));\ntext(await tools.exec_command({cmd:\"pwd\"}));" % json.dumps(verdict)
rollout = os.path.join(codex, "acct", "sessions", "2026", "10", "13",
                       "rollout-2026-10-13T10-00-00-01a13467-57f7-76f2-923a-86bffc845202.jsonl")
transcript(rollout, [
    {"timestamp": iso(T0 + 40), "type": "response_item",
     "payload": {"type": "custom_tool_call", "name": "exec", "call_id": "call_1", "input": js}},
    {"timestamp": iso(T0 + 44), "type": "response_item", "payload": {"type": "custom_tool_call_output", "call_id": "call_1",
                                                                      "output": [{"type": "input_text", "text": "done"}]}}])

calls, bash_calls, chars_s, sessions = t.scan(HI - t.WINDOW_S, HI)
got = sorted((t.cluster(c["cmd"]), c["session"], c["worker"], round(c["exec_s"], 1)) for c in calls)
check(got == [("file-edit", "chat1", False, 30.0), ("ledger-query", "agent-1", True, 5.0),
              ("ledger-query", "chat1", False, 1.0), ("ledger-query", "w1", True, 3.0),
              ("logo-verdict", "01a13467-57f7-76f2-923a-86bffc845202", True, 2.0)],
      "ad-hoc calls in the window with their cluster, session, worker flag (RUN-TOKEN, subagent, codex) and exec "
      "seconds (a codex exec split over its commands); ls, a commit heredoc and a call before the window are out: %s" % got)
check(bash_calls == 9 and sessions == 4,
      "every Bash call in the window counts toward the per-1000 base, every session making one: %s %s" % (bash_calls, sessions))
check(sorted(c["out_b"] for c in calls) == [2] * 5,
      "each call keeps the bytes of its output (a codex exec's split over its commands): %s" % [c["out_b"] for c in calls])
# Without CLAUDE_PROJECTS_DIR the scan reads every Claude transcript root, a claudeb profile's too.
profile = os.path.join(os.environ["HOME"], ".claude-profiles", "acct", "projects", "-p", "prof1.jsonl")
transcript(profile, [bash(T0 + 70, QUERY, "msg_P", "toolu_p1"), result(T0 + 71, "toolu_p1")])
del os.environ["CLAUDE_PROJECTS_DIR"]
seen = {c["session"] for c in t.scan(HI - t.WINDOW_S, HI)[0]}
os.environ["CLAUDE_PROJECTS_DIR"] = projects
check("prof1" in seen, "a claudeb profile's transcripts are scanned with the default root: %s" % sorted(seen))
TOOLS = {"adhoc/ledger-query": t.re.compile(r"\bbin/ledger-rows\b")}
tooled = [c for c in t.scan(HI - t.WINDOW_S, HI, TOOLS)[0] if c.get("tool")]
check([(c["tool"], c["session"], c["exec_s"], c["out_b"]) for c in tooled] == [("adhoc/ledger-query", "w1", 1.0, 2)],
      "a call matching a benched tool's command is that tool's call, ad hoc or not: %s" % tooled)
check(abs(chars_s - len(QUERY) / 2.0) < 0.01,
      "the write rate is a tool_use block's characters over the seconds since its message's previous block: %s" % chars_s)

day = t.day_of(calls, bash_calls, chars_s, HI)
q = day["clusters"]["ledger-query"]
write = 3 * len(QUERY) / chars_s / 60.0
check(q["calls"] == 3 and q["sessions"] == 3 and abs(q["write_min"] - round(write, 2)) < 0.011
      and abs(q["min"] - round(write + 3 * 3.0 / 60.0, 2)) < 0.011,
      "a cluster costs its writing plus calls times the median exec: %s" % q)
check(abs(q["worker_min"] - round(2 * (len(QUERY) / chars_s + 3.0) / 60.0, 2)) < 0.011,
      "worker minutes are the worker calls' share: %s" % q)
check(q["examples"] and q["examples"][0].startswith("python3 - <<'EOF' ⏎ import json"),
      "a cluster keeps its shortest calls on one line as examples: %s" % q["examples"])
LEDGER_EDIT = ("python3 - <<'EOF'\ns=open('share/harness-ledger.json').read().replace('a','b')\n"
               "open('share/harness-ledger.json','w').write(s)\nEOF")
shadowed = t.day_of(calls + [{"session": "chat1", "worker": False, "ts": T0, "cmd": LEDGER_EDIT, "exec_s": 2.0,
                              "out_b": 7}], bash_calls, chars_s, HI, sessions)
check(shadowed["clusters"]["file-edit"]["calls"] == 2 and all(
    shadowed["shadow"][k] == {"calls": 1, "chars": len(LEDGER_EDIT), "exec_s": 2.0, "out_b": 7}
    for k in ("ledger-patch", "ledger-query")) and "json-other" not in shadowed["shadow"],
      "an ad-hoc call an earlier cluster took is a substitute of every later cluster whose pattern it matches: %s"
      % shadowed["shadow"])

t.FLOOR_MIN_DAY = 0.01
history = {t.time_budget.local_day(HI - 1): day}
adopted, found = t.findings(day, history)
check([f["key"] for f in found] == ["ledger-query"] and found[0]["covered_by"] is None and not adopted,
      "a cluster over the floor in fewer than %d sessions stays out: %s" % (t.FLOOR_SESSIONS, found))
check(round(60.0 * t.BUILD_H / t.PAYBACK_D, 1) == 8.6, "the floor is a one-hour fix paid back inside the week")

collected = t.collect(NOW, write=True)
cache = os.path.join(work, "speed", "tool-mining.json")
check(os.path.isfile(cache) and collected["bash_calls"] == 9 and collected["scan_s"] is not None,
      "collect scans the day before and keeps it: %s" % {k: v for k, v in collected.items() if k != "findings"})
os.unlink(rollout)
check(t.collect(NOW + 3600)["bash_calls"] == 9, "a second run the same local day reads the cache, never rescans")
old = t.time_budget.read_json(cache, {})
old["history"][collected["day"]].pop("shadow")
t.time_budget.write_json(cache, old)
t.collect(NOW + 7200, write=True, bench=lambda target: {"command": r"\bbin/ledger-rows\b"} if target == "adhoc/ledger-query" else None)
kept = t.time_budget.read_json(cache, {})["history"][collected["day"]]
check(kept["tools"] == {"adhoc/ledger-query": {"calls": 1, "chars": 25, "exec_s": 1.0, "out_b": 2}} and kept["sessions"] == 3,
      "a cached day without substitutes is rescanned once, a landed fix's bench command marking its tool's calls: %s" % kept)


def part(calls, chars, exec_s, out_b):
    return {"calls": calls, "chars": chars, "exec_s": exec_s, "out_b": out_b}


def at(days_back, residual, tool=None, shadow=None, load=1.0):
    """A scanned day of 1000 Bash calls at 10 chars/s in 10 sessions, three control clusters at `load`."""
    controls = {k: part(5, 500, load, 0) for k in ("suite-history", "worker-runs", "tokenmap")}
    return {"to_s": HI - days_back * 86400, "bash_calls": 1000, "chars_s": 10.0, "sessions": 10,
            "clusters": dict(controls, **({"ledger-query": residual} if residual else {})),
            "shadow": {"ledger-query": shadow} if shadow else {}, "tools": {"adhoc/ledger-query": tool} if tool else {}}


landed = HI - 3 * 86400
SCRIPTS = part(10, 3000, 1.0, 20000)
before = {"d0": {k: v for k, v in at(6, part(1, 1, 0.0, 0)).items() if k != "shadow"}, "d1": at(5, SCRIPTS), "d2": at(4, SCRIPTS), "d3": at(3, SCRIPTS)}
LEAN, RESIDUAL = part(8, 240, 0.3, 2400), part(2, 600, 1.0, 4000)
hist = lambda *after: dict(before, **{"a%d" % i: d for i, d in enumerate(after)})
BENCH = {"command": r"\bbin/ledger-rows\b", "hint_b": 300}
good = t.net(hist(at(2, RESIDUAL, LEAN), at(1, RESIDUAL, LEAN)), "ledger-query", landed, BENCH)
check(good["state"] == "proven" and good["days"] == [3, 2] and good["min_before"] == 5.17 and good["min_after"] == 1.47
      and good["saved_min_day"] == 3.69 and good["cost"] == 0.39 and good["load"] == 1.0,
      "a tool cutting the job's minutes and tokens per 1000 Bash calls is proven, a day without substitutes left out: %s"
      % good)
wordy = t.net(hist(at(2, RESIDUAL, part(8, 240, 0.3, 40000))), "ledger-query", landed, BENCH)
check(wordy["state"] == "worse" and wordy["min_after"] < wordy["min_before"] and wordy["cost"] > 1,
      "a faster tool whose output the model reads costs more tokens is worse: %s" % wordy)
check(t.net(hist(at(2, RESIDUAL, LEAN)), "ledger-query", landed, dict(BENCH, hint_b=3000))["state"] == "worse",
      "the hint's bytes in every session count against the tool")
dodged = t.net(hist(at(2, None, part(2, 60, 0.3, 600), part(10, 3500, 1.0, 20000))), "ledger-query", landed, BENCH)
check(dodged["state"] == "worse" and dodged["saved_min_day"] < 0,
      "scripts doing the job under another cluster's shape count against the tool: %s" % dodged)
busy = t.net({"b": at(4, part(10, 300, 1.0, 5000)), "a": at(2, None, part(10, 100, 4.5, 500), load=3.0)},
             "ledger-query", landed, {"command": BENCH["command"], "hint_b": 0})
check(busy["state"] == "proven" and busy["load"] == 3.0 and busy["min_after"] < busy["min_before"],
      "a tool's exec on a machine three times busier is judged at the load of the other clusters: %s" % busy)
drift = t.net(hist(*[at(2.0 - 0.1 * i, RESIDUAL, LEAN) for i in range(10)]
                   + [at(1.0 - 0.1 * i, RESIDUAL, part(8, 240, 0.3, 24000)) for i in range(t.NET_DAYS)]),
              "ledger-query", landed, BENCH)
check(drift["state"] == "worse", "a proven tool drifting worse over its last %d days reads worse: %s" % (t.NET_DAYS, drift))
check(t.net(before, "ledger-query", landed, BENCH)["state"] == "pending", "no whole day after landing is pending")
nets, found = t.findings(day, history, since=lambda target: HI - 3600 if target == "adhoc/ledger-query" else None)
check(not found and nets["adhoc/ledger-query"]["state"] == "pending",
      "a cluster whose fix landed inside the scanned window is not charged and reads pending: %s %s" % (found, nets))

FAIR = {"command": r"\bbin/ledger-rows\b", "hint_b": 120, "calls": "the two quoted calls on harness", "adhoc_wall_s": 0.4,
        "adhoc_out_b": 900, "tool_wall_s": 0.1, "tool_out_b": 300}
check(t.bench_faults(FAIR) == [] and t.bench_faults(dict(FAIR, command=""), hint_only=True) == [],
      "a bench with the tool at most the ad-hoc median lands; a hint row's tool may be no Bash command")
check(t.bench_faults(None) and t.bench_faults({k: v for k, v in FAIR.items() if k != "hint_b"})
      == ["the bench lacks hint_b"] and t.bench_faults(dict(FAIR, command="")) and t.bench_faults(dict(FAIR, calls=" ")),
      "no bench, a missing key, a tool row with no command or no named calls is refused")
check(t.bench_faults(dict(FAIR, tool_wall_s=0.5)) == ["the tool's wall 0.5 s is over the ad-hoc median's 0.4 s"]
      and t.bench_faults(dict(FAIR, tool_out_b=901, reason="x")) == []
      and t.bench_faults(dict(FAIR, tool_out_b=901)) == ["the tool prints 901 bytes, over the ad-hoc median's 900, with no reason"],
      "a slower tool is refused; a wordier one only with a stated reason")
ledger = {"rows": [{"id": "A", "match": {"rule": "opportunity", "ident": "adhoc/file-edit"}, "fixes": [{"bench": dict(FAIR, command="")}]},
                   {"id": "B", "match": {"rule": "opportunity", "ident": "adhoc/ledger-query"}, "fixes": [{}, {"bench": FAIR}]},
                   {"id": "C", "match": {"rule": "opportunity", "ident": "chat/hooks"}, "fixes": [{}]}]}
check(t.ledger_faults(ledger) == [("B", 0, "no bench {%s}" % ", ".join(t.BENCH))],
      "every fix on an adhoc row carries its bench, a covered row's without a command; other rows are not benched: %s"
      % t.ledger_faults(ledger))

speed_doctor = os.path.join(root, "bin", "speed-doctor")
spec = importlib.util.spec_from_loader("speed_doctor", importlib.machinery.SourceFileLoader("speed_doctor", speed_doctor))
s = importlib.util.module_from_spec(spec)
spec.loader.exec_module(s)
f = t.findings(day, history)[1][0]
rows = s.adhoc_opportunities({"findings": [f, dict(f, key="file-edit", target="adhoc/file-edit",
                                                    covered_by="the Edit tool", job="edit a file")]})
o = rows[0]["opportunity"]
check(rows[0]["id"] == "opportunity:adhoc/ledger-query" and o["kind"] == "tool"
      and abs(o["recoverable_min_day"] - f["write_min_day"]) < 0.011 and o["quality"] == "equivalent"
      and o["what"].startswith("ad-hoc scripts · build one command for the job: read doctor ledger rows")
      and o["examples"] == f["examples"] and o["proof"][0] == s.PROOF["net"],
      "Speed prices an adhoc row at its writing minutes, a new command for it: %s" % rows[0])
check(rows[1]["opportunity"]["kind"] == "hint" and "the Edit tool already does the job" in rows[1]["opportunity"]["what"]
      and rows[1]["fact"].endswith("· the Edit tool"), "a cluster a tool already covers gets the hint only: %s" % rows[1])

h = s.H
entry = {"match": {"rule": "opportunity", "ident": "adhoc/ledger-query"}, "fixes": [{"in": "x"}]}
speed = lambda state: {"adhoc": {"net": {"adhoc/ledger-query": dict(good, state=state)}}}
check(h.speed_proof(entry, speed("proven"), 0)[0] is True and h.speed_proof(entry, speed("worse"), 0)[0] is False
      and h.speed_proof(entry, speed("even"), 0)[0] is False,
      "Harness proves an adhoc fix by its net, not by a replay")
regs = s.adhoc_regressions({"net": {"adhoc/ledger-query": wordy, "adhoc/tokenmap": good}}, {}, NOW)
check([(r["id"], r["rule"], r["state"], r["component"]) for r in regs]
      == [("regression:adhoc/ledger-query", "regression", "new", "adhoc/ledger-query")]
      and regs[0]["fact"].startswith("tool worse than its scripts: adhoc/ledger-query · ") and "cost ×" in regs[0]["fact"]
      and regs[0]["expected_min_day"] == 0.0,
      "Speed turns a worse tool into a regression row the night fixes or cuts, a proven one into none: %s" % regs)
line = s.net_line("adhoc/ledger-query", good)
check(line == "adhoc/ledger-query · 5.2 → 1.5 min/day · saves 3.7 · cost ×0.39 · proven",
      "Speed shows each landed tool's minutes a day before and after, the saving and the cost ratio: %s" % line)
other = {"match": {"rule": "opportunity", "ident": "chat/hooks"}, "fixes": [{"in": "x"}]}
check(h.speed_proof(other, speed("proven"), 0) == (False, "no output-equivalence record on the fix"),
      "another opportunity keeps its output-equivalence proof")
print(count[0])
EOF
) || exit 1
echo "PASS: $asserts asserts"
