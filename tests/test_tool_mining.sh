#!/usr/bin/env bash
. "${BASH_SOURCE%"${BASH_SOURCE##*/}"}lib/suite-journal.sh"
# share/tool_mining.py off fixture transcripts (a chat, a RUN-TOKEN worker, a subagent, a codex rollout): which Bash
# calls are ad hoc, their clusters, exec and writing time, the floor, the once-a-day cache, adoption after a landed
# fix, Speed's adhoc opportunities and Harness's adoption proof. Fixture directories only.
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
    bash(T0 + 5, QUERY, "msg_W", "toolu_w1"), result(T0 + 8, "toolu_w1")])
transcript(os.path.join(projects, "-p", "chat1", "subagents", "agent-1.jsonl"), [
    bash(T0 + 7, QUERY, "msg_S", "toolu_s1"), result(T0 + 12, "toolu_s1")])
verdict = "python3 - <<'PY'\nwith open('results/ab-judge/x/verdicts.csv','a') as f:\n f.write('p1,A,1\\n')\nPY"
js = "text(await tools.exec_command({cmd:%s}));\ntext(await tools.exec_command({cmd:\"pwd\"}));" % json.dumps(verdict)
rollout = os.path.join(codex, "acct", "sessions", "2026", "10", "13",
                       "rollout-2026-10-13T10-00-00-01a13467-57f7-76f2-923a-86bffc845202.jsonl")
transcript(rollout, [
    {"timestamp": iso(T0 + 40), "type": "response_item",
     "payload": {"type": "custom_tool_call", "name": "exec", "call_id": "call_1", "input": js}},
    {"timestamp": iso(T0 + 44), "type": "response_item", "payload": {"type": "custom_tool_call_output", "call_id": "call_1"}}])

calls, bash_calls, chars_s = t.scan(HI - t.WINDOW_S, HI)
got = sorted((t.cluster(c["cmd"]), c["session"], c["worker"], round(c["exec_s"], 1)) for c in calls)
check(got == [("file-edit", "chat1", False, 30.0), ("ledger-query", "agent-1", True, 5.0),
              ("ledger-query", "chat1", False, 1.0), ("ledger-query", "w1", True, 3.0),
              ("logo-verdict", "01a13467-57f7-76f2-923a-86bffc845202", True, 2.0)],
      "ad-hoc calls in the window with their cluster, session, worker flag (RUN-TOKEN, subagent, codex) and exec "
      "seconds (a codex exec split over its commands); ls, a commit heredoc and a call before the window are out: %s" % got)
check(bash_calls == 8, "every Bash call in the window counts toward the per-1000 base: %s" % bash_calls)
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

t.FLOOR_MIN_DAY = 0.01
history = {t.time_budget.local_day(HI - 1): day}
adopted, found = t.findings(day, history)
check([f["key"] for f in found] == ["ledger-query"] and found[0]["covered_by"] is None and not adopted,
      "a cluster over the floor in fewer than %d sessions stays out: %s" % (t.FLOOR_SESSIONS, found))
check(round(60.0 * t.BUILD_H / t.PAYBACK_D, 1) == 8.6, "the floor is a one-hour fix paid back inside the week")

collected = t.collect(NOW, write=True)
cache = os.path.join(work, "speed", "tool-mining.json")
check(os.path.isfile(cache) and collected["bash_calls"] == 8 and collected["scan_s"] is not None,
      "collect scans the day before and keeps it: %s" % {k: v for k, v in collected.items() if k != "findings"})
os.unlink(rollout)
check(t.collect(NOW + 3600)["bash_calls"] == 8, "a second run the same local day reads the cache, never rescans")


def at(days_back, calls_per_1k):
    return {"to_s": HI - days_back * 86400, "bash_calls": 1000, "clusters": {"ledger-query": {"calls": calls_per_1k}}}


landed = HI - 2 * 86400
before = {"d1": at(4, 10), "d2": at(3, 10), "d3": at(2, 10)}
check(t.adoption(dict(before, d4=at(1, 4), d5=at(0, 4)), "ledger-query", landed)
      == {"state": "proven", "before": 10.0, "after": 4.0}, "proven once calls per 1000 fall to half or less")
check(t.adoption(dict(before, d4=at(0, 8)), "ledger-query", landed)["state"] == "not adopted",
      "a rate above half after landing is not adopted")
check(t.adoption(before, "ledger-query", landed)["state"] == "pending", "no whole day after landing is pending")
adopted, found = t.findings(day, history, since=lambda target: HI - 3600 if target == "adhoc/ledger-query" else None)
check(not found and adopted["adhoc/ledger-query"]["state"] == "pending",
      "a cluster whose fix landed inside the scanned window is not charged and reads pending: %s %s" % (found, adopted))

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
      and o["examples"] == f["examples"] and o["proof"][0] == s.PROOF["adoption"],
      "Speed prices an adhoc row at its writing minutes, a new command for it: %s" % rows[0])
check(rows[1]["opportunity"]["kind"] == "hint" and "the Edit tool already does the job" in rows[1]["opportunity"]["what"]
      and rows[1]["fact"].endswith("· the Edit tool"), "a cluster a tool already covers gets the hint only: %s" % rows[1])

h = s.H
entry = {"match": {"rule": "opportunity", "ident": "adhoc/ledger-query"}, "fixes": [{"in": "x"}]}
speed = lambda state: {"adhoc": {"adoption": {"adhoc/ledger-query": {"state": state, "before": 10.0, "after": 4.0}}}}
check(h.speed_proof(entry, speed("proven"), 0)[0] is True and h.speed_proof(entry, speed("not adopted"), 0)[0] is False,
      "Harness proves an adhoc fix by its adoption, not by a replay")
other = {"match": {"rule": "opportunity", "ident": "chat/hooks"}, "fixes": [{"in": "x"}]}
check(h.speed_proof(other, speed("proven"), 0) == (False, "no output-equivalence record on the fix"),
      "another opportunity keeps its output-equivalence proof")
print(count[0])
EOF
) || exit 1
echo "PASS: $asserts asserts"
