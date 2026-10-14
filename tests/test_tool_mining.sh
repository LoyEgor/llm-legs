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
check(bash_calls == 9 and sessions == {"-p": 3, "codex": 1},
      "every Bash call in the window counts toward the per-1000 base, every session making one by project (the "
      "transcript's project directory without a cwd): %s %s" % (bash_calls, sessions))
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
check(found[0]["project"] == "-p" and found[0]["projects"] == 1,
      "a job recurring in fewer than %d projects is its project's: %s" % (t.FLOOR_PROJECTS, found))
check(t.home({"projects": {"a": 3, "b": 3, "c": 3}}) is None and t.home({"projects": {"a": 3, "b": 9, "c": 2, "d": 1}}) == "b",
      "a job is the harness's once it recurs (%d sessions) in %d projects, else the project with most of its sessions"
      % (t.FLOOR_SESSIONS, t.FLOOR_PROJECTS))
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
f = dict(t.findings(day, history)[1][0], project=None)
rows = s.adhoc_opportunities({"findings": [f, dict(f, key="file-edit", target="adhoc/file-edit",
                                                    covered_by="the Edit tool", job="edit a file")]})
o = rows[0]["opportunity"]
check(rows[0]["id"] == "opportunity:adhoc/ledger-query" and o["kind"] == "tool"
      and abs(o["recoverable_min_day"] - f["write_min_day"]) < 0.011 and o["quality"] == "equivalent"
      and o["what"].startswith("model-written scripts · build one command for the job: read doctor ledger rows")
      and o["examples"] == f["examples"] and o["proof"][0] == s.PROOF["net"],
      "Speed prices an adhoc row at its writing minutes, a new command for it: %s" % rows[0])
check(rows[1]["opportunity"]["kind"] == "hint" and "the Edit tool already does the job" in rows[1]["opportunity"]["what"]
      and rows[1]["fact"].endswith("· the Edit tool"), "a cluster a tool already covers gets the hint only: %s" % rows[1])
own = s.adhoc_opportunities({"findings": [dict(f, project="/x/bench")]})[0]
check(own["fact"].startswith("read doctor ledger rows · 3 calls/day in 3 sessions of /x/bench · ")
      and own["opportunity"]["project"] == "/x/bench" and "in /x/bench, its hint in that project's CLAUDE.md" in own["fact"],
      "a project's own job puts its command and hint in that project, a handoff outside the night's: %s" % own["fact"])

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

import subprocess  # noqa: E402
repo, bins, cdir = (os.path.join(work, n) for n in ("repo", "bin", "claude"))
for rel, text in (("bin/foo", "#!/bin/sh\n"), ("bin/bar", "#!/bin/sh\n"), ("skills/s/SKILL.md", "---\nname: s\ndescription: \"do s\"\n---\nbody\n"),
                  ("commands/c.md", "---\ndescription: do c\n---\n"), ("commands/q.md", "---\ndescription: q\ndisable-model-invocation: true\n---\n")):
    os.makedirs(os.path.dirname(os.path.join(repo, rel)), exist_ok=True)
    open(os.path.join(repo, rel), "w").write(text)
git = lambda *a: subprocess.run(["git", "-C", repo] + list(a), check=True, capture_output=True,
                                env=dict(os.environ, GIT_AUTHOR_DATE="@1700000000 +0000", GIT_COMMITTER_DATE="@1700000000 +0000"))
git("init", "-q")
git("-c", "user.name=t", "-c", "user.email=t@t", "add", ".")
git("-c", "user.name=t", "-c", "user.email=t@t", "commit", "-qm", "tools")
os.makedirs(bins)
os.makedirs(cdir)
for name in ("foo", "bar"):
    os.symlink(os.path.join(repo, "bin", name), os.path.join(bins, name))
os.symlink("/usr/bin/true", os.path.join(bins, "ext"))
os.symlink(os.path.join(repo, "skills"), os.path.join(cdir, "skills"))
os.symlink(os.path.join(repo, "commands"), os.path.join(cdir, "commands"))
LINE = "Run `foo --x` first; bar and foo-bar are prose.\n"
open(os.path.join(cdir, "CLAUDE.md"), "w").write("# rules\n" + LINE)
open(os.path.join(repo, "CLAUDE.md"), "w").write("Use `bar`.\n")
open(os.path.join(work, "sweep"), "w").write(repo + "\n")
os.environ.update({"TOOL_BIN_DIR": bins, "TOOL_CLAUDE_DIR": cdir, "NIGHT_RUN_SWEEP_REPOS": os.path.join(work, "sweep")})
tools = t.facing(NOW)
REPO = os.path.realpath(repo)
check(sorted(tools) == ["bin/bar", "bin/foo", "skill/c", "skill/s"] and tools["bin/foo"]["hint_b"] == len(LINE)
      and tools["bin/foo"]["hint_in"] == {"*": len(LINE)} and tools["bin/bar"]["hint_in"] == {REPO: 11}
      and tools["skill/s"]["hint_b"] == len("- s: do s") and all(v["born"] == 1700000000 for v in tools.values()),
      "model-facing tools: a sweep repository's command a backticked CLAUDE.md command names (its line's bytes, loaded "
      "by every session from the global file, by its repository's from the repository's), each skill a model may invoke "
      "(its listed name and description), born at the commit adding it: %s" % tools)

names = t.command_re(["foo", "bar"])
day0 = t.time_budget.local_day(T0)
SCRIPT, RUNS = "print('x')\n" * 3, "cat > /tmp/y.py <<'EOF'\nprint(2)\nEOF\npython3 /tmp/y.py"
transcript(os.path.join(work, "projects2", "-p", "u1.jsonl"), [
    bash(T0, "cd /x && FOO=1 timeout 5 foo --x | jq . && foo-bar; " + repo + "/bin/foo", "msg_U", "toolu_u1"),
    {"type": "assistant", "timestamp": iso(T0 + 1), "message": {"id": "msg_K", "content": [
        {"type": "tool_use", "id": "toolu_k", "name": "Skill", "input": {"skill": "s"}},
        {"type": "tool_use", "id": "toolu_w", "name": "Write", "input": {"file_path": "/tmp/x.py", "content": SCRIPT}}]}},
    {"type": "user", "timestamp": iso(T0 + 2), "message": {"role": "user", "content": "<command-name>/c</command-name>"}},
    bash(T0 + 3, "python3 /tmp/x.py", "msg_R", "toolu_r"), result(T0 + 9, "toolu_r"),
    bash(T0 + 10, "python3 /tmp/x.py", "msg_R2", "toolu_r2"),
    bash(T0 + 11, RUNS, "msg_Y", "toolu_y")])
os.environ["CLAUDE_PROJECTS_DIR"] = os.path.join(work, "projects2")
uses = t.collections.defaultdict(t.collections.Counter)
got = t.scan(HI - t.WINDOW_S, HI, names=names, uses=uses)[0]
os.environ["CLAUDE_PROJECTS_DIR"] = projects
check(dict(uses[day0]) == {"bin/foo": 1, "skill/s": 1, "slash/c": 1},
      "a call counts each command it runs once, by binary name through env, wrappers and paths; Skill calls and typed "
      "slash commands apart: %s" % dict(uses[day0]))
check([(c["cmd"], c["exec_s"]) for c in got] == [("python3 /tmp/x.py\n" + SCRIPT, 6.0), (RUNS, 0.0)],
      "a scratch script written by the Write tool or a cat heredoc is ad hoc in the first call running it, its text "
      "that call's once: %s" % got)

hist = {d: {"uses": {"bin/foo": 1} if d == day0 else {}} for d in t.window(day0, t.USE_DAYS)}
hist[day0].update(sessions=10, chars_s=10.0, projects={REPO: 4, "/y": 6})
tools = {"bin/foo": dict(tools["bin/foo"], born=NOW - 40 * 86400), "skill/s": dict(tools["skill/s"], born=NOW - 40 * 86400),
         "skill/c": dict(tools["skill/c"], born=NOW - 20 * 86400), "bin/bar": dict(tools["bin/bar"], born=NOW - 20 * 86400)}
got = t.adoption(hist, day0, tools, NOW)
check([k for k, v in got.items() if v["unused"]] == ["skill/s"] and got["bin/foo"]["calls_day"] == round(1 / 30.0, 2)
      and got["skill/s"]["hint_tok_day"] == round(9 * 10 / t.CHARS_PER_TOKEN)
      and got["skill/s"]["hint_min_day"] == round(9 * 10 / (t.OUTPUT_EQ * 10.0) / 60.0, 2),
      "a tool with a hint and no call in %d whole days is unused once older than them; its hint priced once a session: "
      "%s" % (t.USE_DAYS, got))
check(got["bin/bar"]["hint_tok_day"] == round(11 * 4 / t.CHARS_PER_TOKEN) and got["bin/bar"]["hint_sessions"] == 4,
      "a repository's hint is charged to its sessions only: %s" % got["bin/bar"])
hist.pop(t.window(day0, t.USE_DAYS)[0])
check(not any(v["unused"] for v in t.adoption(hist, day0, tools, NOW).values()), "a window short of its days finds none")

C = lambda m, w=9.0, n=3: {"min": m, "write_min": w, "sessions": n}
cache = {"history": {day0: {"chars_s": 10.0, "tools": {"adhoc/ledger-query": {"calls": 6, "chars": 600, "exec_s": 10.0}},
                            "clusters": {"ledger-query": C(16.8), "tokenmap": C(24.4), "logo-bench": C(45.5),
                                         "limits": C(4.6, 1.0, 1), "json-other": C(23.8), "text-other": C(49.8, 20.0, 9),
                                         "file-edit": C(217.4)}}},
         "built": ["adhoc/ledger-query", "adhoc/doctor-state"], "parked": ["adhoc/logo-bench"], "unused": ["skill/s", "bin/foo"], "kept": ["skill/s"]}
check(t.menu_row(cache) == [164.9, "model-written scripts", [
    [41.2, "repeated jobs", [[2.0, "ledger-query", [], 16.8], [0.0, "doctor-state", [], 0.0], ["–", "tokenmap", [], 24.4]]],
    [123.7, "one-off", [[45.5, "logo-bench", []], [78.2, "other", []]]]]],
      "the model-written scripts row: repeated jobs (each built tool's min/day beside its residual, then unbuilt "
      "clusters over the floor), one-off (ruled-out or handed-off clusters, catch-alls and the rest as one row): %s"
      % t.menu_row(cache))
check(t.unused_row(cache) == [2, "Unused tools", [[0, "/s", [], "○"], [0, "foo", [], "🗑"]], {"count": True}]
      and t.unused_row(dict(cache, unused=[])) is None,
      "the unused tools under a row counting them, ○ where the fix keeps the file, 🗑 where it deletes it: %s"
      % t.unused_row(cache))
unused = s.unused_opportunities({"unused": [dict(got["skill/s"], key="skill/s")]})
check([o["id"] for o in unused] == ["opportunity:tool/skill/s"] and unused[0]["group"] == "tool"
      and unused[0]["fact"].startswith("skill/s · 0 calls in 30 days · 40 d old · hint 9 B in 10 sessions/day")
      and unused[0]["opportunity"]["quality"] == "equivalent",
      "Speed turns an unused tool into a night row deleting it and its hint: %s" % unused)
tree = os.path.join(repo, ".claude", "worktrees", "w")
git("worktree", "add", "-q", tree)
cwd = lambda row, path: dict(row, cwd=path)
transcript(os.path.join(work, "projects3", "-q", "v1.jsonl"), [
    cwd(bash(T0, QUERY, "msg_V", "toolu_v1"), os.path.join(tree, "bin")), cwd(bash(T0 + 5, QUERY, "msg_V2", "toolu_v2"), "/tmp")])
transcript(os.path.join(codex, "acct", "sessions", "2026", "10", "13", "rollout-2026-10-13T11-00-00-01a13467-57f7-76f2-923a-86bffc845203.jsonl"), [
    {"timestamp": iso(T0), "type": "session_meta", "payload": {"cwd": tree}},
    {"timestamp": iso(T0 + 1), "type": "response_item",
     "payload": {"type": "custom_tool_call", "name": "exec", "call_id": "c", "input": js}}])
os.environ["CLAUDE_PROJECTS_DIR"] = os.path.join(work, "projects3")
got = t.scan(HI - t.WINDOW_S, HI)
os.environ["CLAUDE_PROJECTS_DIR"] = projects
check([c["project"] for c in got[0]] == [REPO] * 3 and got[3] == {REPO: 2},
      "a session's project is its launch cwd's repository, a worktree's main checkout, a later cd aside: %s %s" % (
          [c["project"] for c in got[0]], got[3]))
alias = os.path.join(os.environ["HOME"], ".claude-profiles", "alias", "projects")
os.makedirs(os.path.join(os.environ["HOME"], ".claude"), exist_ok=True)
os.symlink(os.path.dirname(os.path.dirname(profile)), os.path.join(os.environ["HOME"], ".claude", "projects"))
os.makedirs(os.path.dirname(alias))
os.symlink(os.path.dirname(os.path.dirname(profile)), alias)
del os.environ["CLAUDE_PROJECTS_DIR"]
roots = t.projects_roots()
os.environ["CLAUDE_PROJECTS_DIR"] = projects
check(len(roots) == 1, "a transcript root two profiles link to is read once: %s" % roots)
print(count[0])
EOF
) || exit 1
echo "PASS: $asserts asserts"
