#!/usr/bin/env bash
. "${BASH_SOURCE%"${BASH_SOURCE##*/}"}lib/suite-journal.sh"
# share/time_budget.py: one worker run's wall split from its pid start (never the restamped started_at), owner turns
# by partition, the class shares and headline, bands and named holes, the test budget, the levers, the night ledger
# line with its trend and cache, and the daily problem-count rows of share/collector_runs.py. Fixture stores only.
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
WORK="$(cd -P "$(mktemp -d)" && pwd)"
trap 'rm -rf "$WORK"' EXIT
export TZ=UTC HOME="$WORK/home" HARNESS_DOCTOR_DIR="$WORK/harness" DOCTORS_DIR="$WORK/doctors" \
  WORKER_STATS_DIR="$WORK/stats" WORKER_RUN_DIR="$WORK/runs" RUN_SUITES_JOURNAL="$WORK/suites.jsonl" \
  INSTRUCTION_WATCH_STATE="$WORK/watch" NIGHT_RUN_SWEEP_REPOS="$WORK/sweep-repos" MEMLOGD_DIR="$WORK/memlogd" \
  GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
unset HARNESS_WAITS_DIR XDG_CACHE_HOME RUN_SUITES_TIMES CLAUDEB_DIR CHAT_NAME_ROOTS
mkdir -p "$HOME"

D0=1768003200
REPO="$WORK/repo"
git init -q "$REPO"
commit() { # epoch message
  GIT_AUTHOR_DATE="@$1" GIT_COMMITTER_DATE="@$1" git -C "$REPO" -c user.name=t -c user.email=t@t commit -qam "$2"
  git -C "$REPO" rev-parse --short=7 HEAD
}
printf 'a\nb\n' >"$REPO/code.py"
git -C "$REPO" add code.py
GIT_AUTHOR_DATE="@$((D0 - 864000))" GIT_COMMITTER_DATE="@$((D0 - 864000))" \
  git -C "$REPO" -c user.name=t -c user.email=t@t commit -qm base
mkdir -p "$REPO/tests"
printf 'A\nb\nc\nd\n' >"$REPO/code.py"
printf 'x\ny\n' >"$REPO/tests/test_x.sh"
git -C "$REPO" add tests/test_x.sh
JOB=$(commit $((D0 + 500)) "Night job")
printf '1\n2\n3\n4\n' >"$REPO/other.txt"
git -C "$REPO" add other.txt
commit $((D0 + 900)) "Day work" >/dev/null
echo "$REPO" >"$WORK/sweep-repos"

asserts=$(python3 - "$ROOT" "$WORK" "$D0" "$JOB" <<'EOF'
import json, os, shutil, subprocess, sys

root, work, D0, job = sys.argv[1], sys.argv[2], float(sys.argv[3]), sys.argv[4]
sys.path.insert(0, os.path.join(root, "share"))
import collector_runs
import night_spend
import time_budget as T

count = [0]


def check(cond, what):
    count[0] += 1
    if not cond:
        print("FAIL: %s" % what, file=sys.stderr)
        sys.exit(1)


def lines(path, rows):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "a") as handle:
        handle.write("".join(json.dumps(r) + "\n" for r in rows))


def iso(t):
    return T.time.strftime("%Y-%m-%dT%H:%M:%SZ", T.time.gmtime(t))


RUN = "claudeb-%d-1-aaaa" % (D0 + 1000)
run = {"run": RUN, "vendor": "claudeb", "round": None, "pid_started_at": D0 + 1000, "started_at": D0 + 1600,
       "cli_starts": [D0 + 1600, D0 + 2000], "ended_at": D0 + 10000}
review = {"run": "claudeb-%d-2-bbbb" % (D0 + 5000), "round": 3, "pid_started_at": D0 + 5000, "started_at": D0 + 5000,
          "cli_starts": [D0 + 5001], "ended_at": D0 + 5600}
lines(os.path.join(work, "stats", "runs.jsonl"), [run, review])
os.makedirs(os.path.join(work, "runs", RUN))
for name, body in (("session", "abcd1234-0000\n"), ("launcher", "launcher-1\n"),
                   ("meta.json", json.dumps(dict(run, vendor="claudeb")))):
    with open(os.path.join(work, "runs", RUN, name), "w") as handle:
        handle.write(body)
lines(os.path.join(work, "suites.jsonl"), [
    {"kind": "suites", "queued_at": D0 + 3000, "started_at": D0 + 4000, "ended_at": D0 + 6000, "worker_run": RUN,
     "session": None, "suites": {"test_a.sh": {"rc": 0, "secs": 50}, "test_b.sh": {"rc": 0, "secs": 1900}}},
    {"kind": "direct", "queued_at": D0 + 8000, "started_at": D0 + 8000, "ended_at": D0 + 8100, "worker_run": None,
     "session": "chat-1", "suites": {"test_a.sh": {"rc": 0, "secs": 100}}}])
turn = ["t", D0 + 3600, "sessA", D0 + 4600, "n", [0, 0, 0], 0, [], [],
        {"gen": 400, "tool": 300, "hook": 100, "stop": 20, "test": 80, "resid": 50, "dark": 50},
        {"m": [2, 10, 0, 1000, 9000]}, []]
lines(os.path.join(work, "harness", "events", "2026-01-10.jsonl"), [
    turn,
    ["c", D0 + 4500, "p", "Bash", 0, 300, "w", "tid0000002", "abcd1234", 1],
    ["c", D0 + 7000, "p", "Bash", 0, 600, "w", "tid0000001", "abcd1234", 1],
    ["c", D0 + 7100, "p", "Read", 0, 10, "c", "tid0000003", "sessA", 1],
    ["h", D0 + 7001, "p", "PreToolUse", "gate", 100000, "Bash", "tid0000001"],
    ["s", D0 + 100, "work", "worker", 3.0, 0.5, "1"]])
lines(os.path.join(work, "harness", "waits", "2026-01-10.jsonl"),
      [{"class": "lock", "source": "x", "started": D0 + 7100, "seconds": 40, "pid": 1, "caller": "sessA"},
       {"class": "lock", "source": "heartbeat", "started": D0 + 7200, "seconds": 30, "pid": 2},
       {"class": "workers", "source": "j", "started": D0 + 1000, "seconds": 600, "pid": 1},
       {"class": "review-cells", "source": "cell c of r", "started": D0 + 1100, "seconds": 45, "pid": 3}])
lines(os.path.join(work, "watch", "gates.jsonl"), [{"at": D0 + 100, "decision": "denied"},
                                                   {"at": D0 + 100, "decision": "passed"}])

old_gates = T.gates_path
fixture = os.path.join(work, "recovery.jsonl")
T.gates_path = lambda: fixture
lines(fixture, [
    {"at": D0 + 101, "gate": "write", "decision": "denied", "sid": "recover1-full", "source": "journal"},
    {"at": D0 + 111, "gate": "write", "decision": "denied", "sid": "recover1-full", "tool_use_id": "denied2"},
    {"at": D0 + 201, "gate": "relay", "decision": "relay-refused", "sid": "recover2", "tool_use_id": "denied3"},
    {"at": D0 + 301, "gate": "cap", "decision": "denied", "sid": "recover3", "tool_use_id": "denied4"},
    {"at": D0 + 301, "gate": "legacy", "decision": "denied", "sid": "missing1"},
    {"at": D0 + 301, "gate": "passed", "decision": "passed", "sid": "recover3"}])
def call(t, tid, sid):
    return ["c", D0 + t, "p", "Bash", 0, 5, "c", tid, sid, 1]
recovery_events = {"c": [call(100, "denied1", "recover1"), call(110, "denied2", "recover1"),
                          call(120, "accepted", "recover1"), call(105, "elsewhere", "another"),
                          call(200, "denied3", "recover2"), call(300, "denied4", "recover3"),
                          call(230, "accepted2", "recover2"), call(1000, "accepted3", "recover3")],
                   "h": [["h", D0 + 124, "p", "PostToolUse", "hook", 1, "Bash", "accepted"]],
                   "t": [["t", D0 + 190, "recover2", D0 + 230],
                         ["t", D0 + 290, "recover3", D0 + 1000]]}
recovery_events["c"][-1][6] = "h"
cost = T.refusal_cost(D0, D0 + 86400, recovery_events)
check(cost["seconds"] == 348 and cost["by_gate_s"] == {"cap": 300, "write": 19, "relay": 29}
      and cost["measured"] == 4 and cost["unmeasured_by_gate"] == {"legacy": 1},
      "session/time refusal links need no call ID, skip known denied retries and other sessions, cap and name missing "
      "calls, and charge a window two denials share once: %s" % cost)
check(cost["chat_s"] == 348, "overlapping retries are charged once in the wall partition")
check(T.refusal_cost(D0 + 115, D0 + 125, recovery_events)["seconds"] == 5,
      "recovery intervals are clipped at both reporting window boundaries")
for row in recovery_events["t"]:
    row.extend(["n", [0, 0, 0], 0, [], [], {"gen": row[3] - row[1]}, {}, []])
recovery_events["t"].append(["t", D0 + 90, "recover1", D0 + 150, "n", [0, 0, 0], 0, [], [],
                              {"gen": 60}, {}, []])
charged = T.budget(D0, D0 + 86400, recovery_events)
check(charged["seconds"]["refusal"] == 348 and charged["seconds"]["model"] >= 0,
      "measured recovery moves from model time to the harness class without double charging retries")
transcript = os.path.join(work, "home", ".claude", "projects", "fixture", "recover4-full.jsonl")
lines(transcript, [
    {"timestamp": iso(D0 + 500), "message": {"content": [
        {"type": "tool_result", "tool_use_id": "blocked4", "is_error": True,
         "content": "PreToolUse:Bash hook error: [worker-limit-gate.sh] Blocked"}]}},
    {"timestamp": iso(D0 + 505), "message": {"content": [
        {"type": "tool_result", "tool_use_id": "blocked5", "is_error": True,
         "content": [{"type": "text", "text": "PreToolUse:Bash hook error: [review-flow-gate.sh] Blocked"}]}]}},
    {"timestamp": iso(D0 + 506), "message": {"content": [
        {"type": "tool_result", "tool_use_id": "ordinary", "is_error": True, "content": "command failed"}]}},
    {"timestamp": iso(D0 + 507), "message": {"content": [
        {"type": "text", "text": "PreToolUse:Bash hook error: [fake.sh] quoted text"}]}}])
extra = {"c": [call(499, "blocked4", "recover4"), call(504, "blocked5", "recover4"),
               call(520, "accepted4", "recover4")]}
extra_cost = T.refusal_cost(D0 + 490, D0 + 530, extra)
check(extra_cost["by_gate_s"] == {"worker-limit-gate.sh": 5, "review-flow-gate.sh": 15}
      and extra_cost["chat_s"] == 20 and extra_cost["count"] == 2,
      "native transcript denials count per hook, exclude denied c rows, and ignore ordinary errors and quoted text")
lines(fixture, [{"at": D0 + 499, "sid": "recover4-full", "gate": "worker-limit", "decision": "denied"}])
extra_cost = T.refusal_cost(D0 + 490, D0 + 530, extra)
check(extra_cost["count"] == 2 and extra_cost["by_gate_s"] == {"worker-limit": 6, "review-flow-gate.sh": 15},
      "a transcript denial enriches its journal row without charging it twice")
profile = os.path.join(work, "home", ".claude-profiles", "fixture", "projects", "fixture",
                       "recover4-full", "subagents", "agent-fixture.jsonl")
lines(profile, [
    {"timestamp": iso(D0 + 500), "message": {"content": [
        {"type": "tool_result", "tool_use_id": "blocked4", "is_error": True,
         "content": "PreToolUse:Bash hook error: [worker-limit-gate.sh] Blocked"}]}},
    {"timestamp": iso(D0 + 508), "message": {"content": [
        {"type": "tool_result", "tool_use_id": "blocked6", "is_error": True,
         "content": "PreToolUse:Bash hook error: [cd-guard.sh] Blocked"}]}},
    {"timestamp": iso(D0 + 509), "message": {"content": [
        {"type": "tool_result", "tool_use_id": "blocked7", "is_error": True,
         "content": "PreToolUse:Bash hook error: Unnamed denial"}]}}])
extra_cost = T.refusal_cost(D0 + 490, D0 + 530, extra)
check(extra_cost["count"] == 4 and extra_cost["by_gate_s"]["cd-guard.sh"] == 1
      and extra_cost["by_gate_s"]["unknown-hook"] == 11 and extra_cost["seconds"] == extra_cost["chat_s"] == 21,
      "profile subagent transcripts use the parent session, deduplicate copied calls and retain unnamed hooks")
os.unlink(profile)
os.unlink(transcript)
blocks = os.path.join(work, "home", ".claude", "projects", "fixture", "recover5-full.jsonl")
stop = {"timestamp": iso(D0 + 600), "uuid": "stop-1", "attachment": {
    "type": "hook_blocking_error", "hookEvent": "Stop", "hookName": "Stop",
    "blockingError": {"blockingError": "[~/.claude/hooks/ask-span-drill.sh]: write the reading line"}}}
lines(blocks, [stop, stop,
               {"timestamp": iso(D0 + 640), "uuid": "post-1", "attachment": {
                   "type": "hook_blocking_error", "hookEvent": "PostToolUse", "hookName": "PostToolUse:Bash",
                   "blockingError": "commit journal: files left owned by nobody"}},
               {"timestamp": iso(D0 + 645), "uuid": "pre-1", "attachment": {
                   "type": "hook_blocking_error", "hookEvent": "PreToolUse", "blockingError": "[x.sh]: counted as a tool result"}},
               {"timestamp": iso(D0 + 700), "uuid": "stop-2", "attachment": {
                   "type": "hook_blocking_error", "hookEvent": "Stop", "blockingError": {"blockingError": "rewrite"}}}])
blocked = T.refusal_cost(D0 + 590, D0 + 1200, {"c": [call(650, "after-post", "recover5"), call(1100, "late", "recover5")],
                                                 "t": [["t", D0 + 590, "recover5", D0 + 620]]})
check(blocked["by_gate_s"] == {"ask-span-drill.sh": 20, "unknown-posttooluse-hook": 10} and blocked["count"] == 3
      and blocked["unmeasured_by_gate"] == {"unknown-stop-hook": 1} and blocked["chat_s"] == 30,
      "a Stop block recovers until its turn ends, a PostToolUse block until the next call, a copied block counts once, "
      "and a block with no turn and no call within the cap stays unmeasured: %s" % blocked)
os.unlink(blocks)
T.gates_path = old_gates
baseline = T.budget(D0, D0 + 86400, recovery_events)
check(sum(charged["seconds"].values()) == sum(baseline["seconds"].values()),
      "reclassifying recovery preserves total measured wall time")

split = T.run_split(run, 0, 1e12, T.suite_rows(0, 1e12), T.event_rows(D0, D0 + 86400)["c"],
                    T.event_rows(D0, D0 + 86400)["h"])
check(dict((k, round(v)) for k, v in split.items() if v) == {
    "slot": 600, "retries": 400, "suite_wait": 1000, "suite_run": 2000, "tools": 500, "hooks": 100, "model": 4400}
      and round(sum(split.values())) == 9000,
      "a worker run's wall starts at its pid, not the restamped started_at: slot queue, retries, its own suites "
      "(the call inside them absorbed), tools net of their hooks, the rest model: %s" % dict(split))
walled = T.run_split(dict(run, walled=["com"]), 0, 1e12, T.suite_rows(0, 1e12), T.event_rows(D0, D0 + 86400)["c"],
                     T.event_rows(D0, D0 + 86400)["h"])
check(not walled["retries"] and round(walled["walled"]) == 400 and round(walled["model"]) == 4400
      and round(walled["slot"]) == 600 and round(sum(walled.values())) == 9000,
      "a walled run's earlier attempts are weather, neither retries nor work: %s" % dict(walled))
bench = T.run_split(dict(run, workdir="/w/logo-vectorizer-bench/lane"), 0, 1e12, T.suite_rows(0, 1e12),
                    T.event_rows(D0, D0 + 86400)["c"], T.event_rows(D0, D0 + 86400)["h"])
check(dict(bench) == {"bench": 9000} and T.worker_wall({"model": 60, "bench": 9000}) == 60,
      "a bench worker is its own class, whole, outside the workers' wall: %s" % dict(bench))
clipped = T.run_split(run, D0 + 5000, D0 + 7300, T.suite_rows(0, 1e12), [], [])
orphan = T.run_split(dict(run, run="claudeb-1-9-none"), 0, 1e12, [], [], [])
check(round(clipped["suite_run"]) == 1000 and round(clipped["model"]) == 1300 and round(sum(clipped.values())) == 2300
      and round(orphan["other"]) == 8000 and not orphan["model"],
      "a window clips every span, and a run with no session file is unsplit, never model: %s %s"
      % (dict(clipped), dict(orphan)))
late = T.run_split(run, D0 + 7700, D0 + 10000, T.suite_rows(0, 1e12),
                   T.event_rows(D0, D0 + 86400)["c"] + [["c", D0 + 8500, "p", "Bash", 0, 200, "w", "tid0000009", "abcd1234", 1]],
                   T.event_rows(D0, D0 + 86400)["h"])
check(round(late["hooks"]) == 0 and round(late["tools"]) == 200,
      "a call outside the window takes its hooks with it, never out of the window's tool time: %s" % dict(late))

def memlogd(samples):
    for name in ("machine", ""):
        path = os.path.join(work, "memlogd", name, "2026-01-10.log")
        os.makedirs(os.path.dirname(path), exist_ok=True)
        with open(path, "w") as handle:
            handle.write("JUMP %d node_count=9 avail_mb=1\n" % (D0 + 3000))
            for t, load, avail in samples:
                handle.write("%d load1=%s ncpu=10 swap_mb=0\n" % (D0 + t, load) if name else
                             "%d quiet avail_mb=%d swap_used_mb=0\n" % (D0 + t, avail))


memlogd([(t, 2.0, 8000) for t in range(2900, 4101, 15)])
NOW = D0 + 20 * 3600
for back in range(1, 8):
    day = T.local_day(D0 - back * 86400)
    T.write_json(T.day_cache_path(day), {"settled": True, "seconds": {"suite_wait": 100, "suite_run": 1100, "model": 5000},
                                         "worker": {}})
doc = T.document(NOW)
check(doc["refusal_cost"]["unmeasured_by_gate"] == {"unknown": 1}
      and doc["refusal_cost"]["min_day"] == 0
      and any(r["class"] == "refusal" and r["floor_min_day"] == 0 for r in doc["floors"]),
      "JSON reports the refusal cost coverage and a zero-floor harness class")
by = {r["class"]: r for r in doc["classes"]}
check(by["model"]["min"] == 80.0 and by["tools"]["min"] == round(760 / 60.0, 1) and by["locks"]["min"] == round(40 / 60.0, 1)
      and by["review"]["min"] == 10.0 and by["suite_run"]["min"] == round(2080 / 60.0, 1)
      and by["other"]["min"] == round(50 / 60.0, 1) and doc["refusals"] == 1 and doc["worker_runs"] == 2,
      "the classes add owner turns (dark time out) to worker runs, lock and poll waits a chat or worker paid come out "
      "of tool time (a background job's never), a review "
      "round is its own class, gate refusals are counted: %s" % {k: v["min"] for k, v in by.items()})
check(doc["total_min"] == round(10550 / 60.0, 1) and doc["harness_share"] == round(4940 / 10550.0, 3)
      and doc["lines"][0] == "Without the harness ≈ 47 % faster: 82 min of 2.9 h in 24 h"
      and abs(sum(r["share"] for r in doc["classes"]) - 1) < 0.01,
      "the headline is the harness classes over the total, the shares sum to one: %s" % doc["lines"][0])
check(doc["band_days"] == 7 and by["suite_wait"]["usual_min"] == round(100 / 60.0, 1)
      and doc["holes"][-1:] == ["suite slot wait: 17 min, usually 2 min"]
      and "unknown: 1" in doc["holes"][0]
      and "Hole: suite slot wait: 17 min, usually 2 min" in doc["lines"],
      "a harness class past twice its 7-day median by 15 minutes is a named hole; one under twice its median, one "
      "under the floor or a plain class never is: %s" % doc["holes"])
long = T.document(NOW, 72.0, write=False)
check(len(long["holes"]) == 1 and "unmeasured" in long["holes"][0] and {r["class"]: r["usual_min"] for r in long["classes"]}["suite_wait"] == 5.0,
      "a 72 h window is judged against three usual days, never one: %s" % long["holes"])
check(T.holes({"worker": {"model": 900, "suite_run": 4500, "slot": 4600}, "seconds": {}}, {})
      == ["workers worked 9 % of their time; 46 % went to the slot queue"]
      and T.holes({"worker": {"model": 4000, "suite_run": 6000}, "seconds": {}}, {}) == [],
      "workers under 30 % model time are a named hole, at 40 % they are not")
check("tests" not in doc and not any(l.startswith("Tests:") for l in doc["lines"]),
      "test time is share/test_health.py's block, never a second line here")
lever = {x["lever"]: x for x in doc["levers"]}
check(lever["prompt-cache hits"]["value"] == "90 % of cached input read from cache"
      and lever["parallel tool calls"]["value"] == "0 % of 3 tool calls ran beside another"
      and lever["fewer process starts"]["value"] == "1 CLI starts, 0.1 min launching"
      and lever["smaller context per turn"]["measured"] is False,
      "levers are measured where the journals hold the data and marked ideas where not: %s" % lever)
gap = {f["class"]: (f["chat_min_day"], f["worker_min_day"]) for f in doc["floors"]}
check(gap == {"refusal": (0.0, 0.0), "hooks": (1.7, 1.7), "stop": (0.3, 0.0), "suite_wait": (0.0, 16.7), "slot": (0.0, 0.0),
              "retries": (0.0, 6.7), "dead": (0.0, 0.0), "locks": (0.7, 0.0), "suite_run": (0.7, 0.0)},
      "each class is judged against its floor, chats' and workers' parts apart: zero for hooks, gates and waits, "
      "none for plain Claude Code: %s" % gap)
check(T.suite_floor(D0, D0 + 86400) == {"worker": 1.0, "chat": 0.5} and gap["suite_run"] == (0.7, 0.0),
      "suites keep their uncontended p10 wall: only a caller's suite seconds above each suite's p10 are recoverable, "
      "never a flat budget: %s" % T.suite_floor(D0, D0 + 86400))
failed = os.path.join(work, "suites-failed.jsonl")
lines(failed, [{"kind": "direct", "queued_at": D0 - 86400, "started_at": D0 - 86400, "ended_at": D0 - 86399,
                "worker_run": None, "session": "chat-2", "suites": {"test_a.sh": {"rc": 1, "secs": 1}}}]
      + list(night_spend.rows(os.environ["RUN_SUITES_JOURNAL"])))
os.environ["RUN_SUITES_JOURNAL"], journal = failed, os.environ["RUN_SUITES_JOURNAL"]
check(T.suite_floor(D0, D0 + 86400) == {"worker": 1.0, "chat": 0.5},
      "a failed run that stopped at its first check is no suite's floor: %s" % T.suite_floor(D0, D0 + 86400))
os.environ["RUN_SUITES_JOURNAL"] = journal
critical = [[0, 0, 100, 60], [0, 100, 200, 60], [1000, 1000, 1100, 50]]
idle = [[0, 0, 1000, 0], [0, 0, 100, 50], [0, 100, 200, 50]]
check(T.slot_gain(critical) == 60 and T.slot_gain(idle) == 0 and gap["slot"] == (0.0, 0.0)
      and by["slot"]["min"] == 10.0,
      "the slot queue is priced by what lending slots during suites moves the bursts' ends, so a queue off the "
      "critical path recovers nothing: %s %s" % (T.slot_gain(critical), T.slot_gain(idle)))
active = T.worker_floor({"model": 900, "suite_run": 4500, "slot": 4600, "bench": 5000},
                        {"suite_run": (300, 1500), "slot": (0, 600)}, 1)
check(active == {"share": 0.09, "floor_share": 0.114, "recoverable_min_day": 35.0,
                 "parts": {"suite_run": 25.0, "slot": 10.0}},
      "workers' floor share is derived: model time over the wall left once every part is at its floor, bench "
      "outside the wall; the parent's recoverable is the sum of its parts: %s" % active)
check(doc["workers_active"]["floor_share"] == 0.543 and doc["workers_active"]["recoverable_min_day"] == 25.0
      and doc["lost_min_day"] == 28.3
      and doc["lines"][1:4] == ["Chats 16 min · workers 2.7 w-h", "Over the floor: chats 3 min/day · hooks 2 min",
                                "Workers active 46 % of their wall (floor 54 %) · over it 25 w-min/day · suite slot "
                                "wait 17 w-min · retries and relaunches 7 w-min · hooks 2 w-min"],
      "workers active is the parent of its parts, the headline counts each minute once, worker-minutes carry "
      "their own unit: %s %s" % (doc["lost_min_day"], doc["lines"][1:4]))
lines(os.path.join(work, "night-stats", "runs.jsonl"), [dict(run, workdir="/r/.claude/worktrees/night-x-y")])
os.environ["WORKER_STATS_DIR"] = os.path.join(work, "night-stats")
check(T.budget(D0, D0 + 86400)["jobs"] == [[D0 + 1000, D0 + 1600, D0 + 10000, 3000.0]],
      "a night worker enters the slot replay with its launch, first CLI start, end and own suite seconds")
check(T.budget(D0 + 7000, D0 + 86400)["jobs"] == [[D0 + 1000, D0 + 1600, D0 + 10000, 3000.0]],
      "a night worker that started before the window keeps the suite seconds it ran before it")
lines(os.path.join(work, "day-stats", "runs.jsonl"), [dict(run, workdir="/r/.claude/worktrees/feat-x"),
                                                      dict(review, workdir="/r/.claude/worktrees/feat-x")])
os.environ["WORKER_STATS_DIR"] = os.path.join(work, "day-stats")
check(T.budget(D0, D0 + 86400)["jobs"] == [[D0 + 1000, D0 + 1600, D0 + 10000, 3000.0]],
      "a day worker takes a slot from the same pool and enters the slot replay too; a review round stays out")
check(dict(T.unit_samples({"class": "slot"}, D0, D0 + 86400)) == {"workers": [600], "review-cells": [45]},
      "the slot class's unit samples are the one admission's waits: the workers pool's and the review cells'")
os.environ["WORKER_STATS_DIR"] = os.path.join(work, "stats")
b = T.budget(D0, D0 + 86400)
wb = dict(b, seconds=dict(b["seconds"], walled=3600), worker=dict(b["worker"], walled=3600))
rec, wrec = T.recoverable(b, D0, D0 + 86400), T.recoverable(wb, D0, D0 + 86400)
check(sum(map(sum, wrec.values())) - sum(map(sum, rec.values())) == 0
      and T.worker_floor(wb["worker"], wrec, 1) == T.worker_floor(b["worker"], rec, 1),
      "a walled run's relaunch minutes add 0 to lost_min_day and leave the workers' shares alone: usage walls are "
      "weather: %s" % wrec)
check(b["free_s"] == {"suite_wait": 1000.0, "slot": 0.0} and rec["suite_wait"] == (0.0, 1000.0) and rec["slot"] == (0.0, 0.0),
      "a suite wait the machine had room through is lost whole; a slot queue memlogd never sampled is busy: %s"
      % b["free_s"])
memlogd([(t, 12.0 if t in (3500, 20090) else 2.0, 1000 if t == 20195 else 8000)
         for t in list(range(2900, 4101, 15)) + list(range(20000, 20301, 15))])
free = T.free_spans(D0 + 20000, D0 + 20500)
lines(os.path.join(work, "harness", "waits", "2026-01-10.jsonl"),
      [{"class": "night-workers", "source": "w", "started": D0 + 20300, "seconds": 30, "pid": 4, "reason": "room"},
       {"class": "night-workers", "source": "w", "started": D0 + 20000, "seconds": 30, "pid": 5, "reason": "limit"}])
roomless = T.free_spans(D0 + 20000, D0 + 20500)
check(T.length(free) == 330 and free[-1] == [D0 + 20210, D0 + 20360]
      and T.length(roomless) == 300 and roomless[-2:] == [[D0 + 20210, D0 + 20300], [D0 + 20330, D0 + 20360]],
      "the machine is free where memlogd's load1 is under its cores and available RAM at or over its incident "
      "threshold, and never through a slot wait refused for room; a sample covers at most a minute, past it the "
      "machine counts busy: %s %s" % (free, roomless))
busy = T.budget(D0, D0 + 86400)
check(busy["free_s"]["suite_wait"] == 985.0 and T.recoverable(busy, D0, D0 + 86400)["suite_wait"] == (0.0, 985.0),
      "only a wait's free part is recoverable, its busy part is the floor: %s" % busy["free_s"])
check([T.recoverable(dict(b, jobs=critical, worker=dict(b["worker"], slot=500), free_s={"slot": s}), D0, D0 + 86400)["slot"]
       for s in (30.0, 100.0)] == [(0.0, 30.0), (0.0, 60.0)],
      "the slot queue recovers its free part, never more than lending slots during suites moves")
shutil.rmtree(os.path.join(work, "memlogd"))
bare = T.budget(D0, D0 + 86400)
check(bare["free_s"] == {"suite_wait": 0.0, "slot": 0.0} and T.recoverable(bare, D0, D0 + 86400)["suite_wait"] == (0.0, 0.0),
      "with no memlogd sample a wait is busy: undercount, never a guess")
memlogd([(t, 2.0, 8000) for t in range(2900, 4101, 15)])

DEAD = "claudeb-%d-5-dddd" % (D0 + 30000)
dead_row = {"run": DEAD, "status": "failed", "round": None, "pid_started_at": D0 + 30000, "started_at": D0 + 30000,
            "cli_starts": [D0 + 30010], "ended_at": D0 + 30610, "workdir": "/w/feat"}
dead_files = {"session": "dead0001-aaaa", "worker-session": "dead0001-aaaa", "files": "WORKDIR: /w/feat\n",
              "head-before": "abc\n", "head-after": "abc\n", "produced": "", "files-external": "",
              "result": "Failed to authenticate: OAuth session expired and could not be refreshed\n",
              "brief": "EFFORT: low\n\nRESUME dead0001-aaaa: its own resume is no continuation\n"}
def run_dir(run, files):
    folder = os.path.join(work, "runs", run)
    shutil.rmtree(folder, ignore_errors=True)
    os.makedirs(folder)
    for name, body in files.items():
        with open(os.path.join(folder, name), "w") as handle:
            handle.write(body)
run_dir(DEAD, dead_files)
check(T.dead_runs([dead_row]) == {DEAD}
      and dict(T.run_split(dict(dead_row, dead=True), 0, 1e12, [], [], [])) == {"slot": 10, "retries": 0, "dead": 600},
      "a failed run nobody resumed, with no file, commit or report, is dead: its last attempt's wall, the slot queue "
      "before it kept apart")
alive = {"files names a path": dict(dead_files, files="WORKDIR: /w/feat\nsrc/a.py\n"),
         "files partial": dict(dead_files, files="WORKDIR: /w/feat\nPARTIAL: the run also ran shell commands\n"),
         "files unknown": dict(dead_files, files="UNKNOWN: the workdir after snapshot could not be established\n"),
         "no files record": {k: v for k, v in dead_files.items() if k != "files"},
         "head moved": dict(dead_files, **{"head-after": "def\n"}),
         "no head after": {k: v for k, v in dead_files.items() if k != "head-after"},
         "produced": dict(dead_files, produced="-\tabc\tsrc/a.py\tedit\n"),
         "wrote outside": dict(dead_files, **{"files-external": "/tmp/x\n"}),
         "a report": dict(dead_files, result="Failed to authenticate.\nDone: the fixture passes, 3 files read\n"),
         "a long error": dict(dead_files, result="API Error: " + "x" * 400 + "\n")}
kept = [why for why, files in alive.items() if run_dir(DEAD, files) or T.dead_runs([dead_row])]
run_dir(DEAD, dead_files)
check(kept == [] and T.dead_runs([dict(dead_row, status="done")]) == T.dead_runs([dict(dead_row, round=2)])
      == T.dead_runs([dict(dead_row, workdir="/w/logo-vectorizer-bench")]) == set(),
      "a changed file, an unknown or partial listing, a missing record, a moved HEAD, produced content, a write "
      "outside, a report or a done, review or bench run is never dead: %s" % kept)
run_dir("claudeb-%d-6-eeee" % (D0 + 20000), {"brief": "RESUME dead0001-aaaa: an earlier resume\n",
                                             "meta.json": json.dumps({"pid_started_at": D0 + 20000})})
earlier = T.dead_runs([dead_row])
run_dir("claudeb-%d-7-ffff" % (D0 + 40000), {"brief": "EFFORT: low\nACCOUNT: x\n\nRESUME dead0001-aaaa: go on\n",
                                             "meta.json": json.dumps({"pid_started_at": D0 + 40000})})
by_brief = T.dead_runs([dead_row])
run_dir("claudeb-%d-7-ffff" % (D0 + 40000), {"meta.json": json.dumps({"pid_started_at": D0 + 40000,
                                                                      "resume": "dead0001-aaaa"})})
by_launch = T.dead_runs([dead_row])
shutil.rmtree(os.path.join(work, "runs", "claudeb-%d-7-ffff" % (D0 + 40000)))
check(earlier == {DEAD} and by_brief == by_launch == set(),
      "a later run's RESUME brief or resume launch continues the session, so the failed run is no dead work; an "
      "earlier run's resume is not: %s %s %s" % (earlier, by_brief, by_launch))
lines(os.path.join(work, "dead-stats", "runs.jsonl"), [dead_row])
os.environ["WORKER_STATS_DIR"] = os.path.join(work, "dead-stats")
died = T.budget(D0, D0 + 86400)
os.environ["WORKER_STATS_DIR"] = os.path.join(work, "stats")
check(died["seconds"]["dead"] == 600 and died["dead_runs"] == [DEAD]
      and T.recoverable(died, D0, D0 + 86400)["dead"] == (0.0, 600.0) and T.KIND["dead"] == "harness",
      "dead worker runs are a harness class over a floor of zero: %s" % died["seconds"])
section = T.section(NOW)
check(open(os.path.join(work, "harness", "budget.txt")).read().splitlines() == section["lines"]
      and not os.path.exists(T.day_cache_path("2026-01-10")),
      "the section writes the plain-words block beside the document and never caches an unsettled day")

collector_runs.problem_day("llm", {"problem_count": 3, "status": "problems"}, "LLM_DOCTOR_DIR", now=D0 + 10)
collector_runs.problem_day("llm", {"problem_count": 1, "status": "problems"}, "LLM_DOCTOR_DIR", now=D0 + 20)
collector_runs.problem_day("harness", {"problem_count": None, "status": "error"}, "HARNESS_DOCTOR_DIR", now=D0 + 20)
collector_runs.problem_day("code", {"problem_count": 2, "status": "problems"}, "CODE_DOCTOR_DIR", now=D0 - 40 * 86400)
collector_runs.problem_day("code", {"problem_count": 0, "status": "ok"}, "CODE_DOCTOR_DIR", now=D0 + 30)
rows = collector_runs.problem_days(None)
check(sorted((r["doctor"], r["day"], r["count"], r["max"]) for r in rows)
      == [("code", "2026-01-10", 0, 0), ("llm", "2026-01-10", 1, 3)],
      "one row per doctor per day, the latest count with the day's max, no row for a null count, days past 35 pruned: "
      "%s" % rows)
check(T.problem_trend(NOW) == {"code": {"2026-01-10": 0}, "llm": {"2026-01-10": 1}}, "the budget carries the 7-day trend")
env = dict(os.environ, LLM_DOCTOR_DIR=os.path.join(work, "llm"))
env.pop("DOCTORS_DIR")
subprocess.run([sys.executable, "-c", "import sys; sys.path.insert(0, sys.argv[1]); import collector_runs as c; "
                "c.problem_day('llm', {'problem_count': 5}, 'LLM_DOCTOR_DIR')", os.path.join(root, "share")], env=env)
check(not os.path.exists(os.path.join(work, "home", ".cache", "doctors")),
      "a fixture doctor directory with no DOCTORS_DIR never reaches the default journal")

nights = os.path.join(work, "doctors", "nights")
os.makedirs(nights)
night = {"id": "N1", "started_at": iso(D0), "finished_at": iso(D0 + 11000), "session": "launcher-1",
         "jobs": [{"kind": "fixer", "ref": "harness-x-20260110T000000Z", "state": "merged",
                   "commits": [{"repo": "repo", "hash": job}]},
                  {"kind": "fixer", "ref": "harness-y-20260110T000000Z", "state": "left", "commits": []},
                  {"kind": "fixer", "ref": "llm-z-20260110T000000Z", "state": "merged", "commits": []},
                  {"kind": "debt", "ref": "debt", "state": "left", "commits": []}],
         "doctors_before": {"llm": 5, "harness": 3}, "doctors_after": {"llm": 4, "harness": 3},
         "doctor_states_after": {"llm": {"proved": 1, "regressed": 0}}, "doctor_problems_after": {}}
older = {"id": "N0", "started_at": iso(D0 - 86400), "finished_at": iso(D0 - 80000), "session": "nobody",
         "jobs": [], "doctors_before": {"llm": 6}, "doctors_after": {"llm": 5}}
for item in (night, older):
    with open(os.path.join(nights, item["id"] + ".json"), "w") as handle:
        json.dump(item, handle)
os.makedirs(os.path.join(work, "doctors", "runs"))
for ref, problem in (("harness-x-20260110T000000Z", {"id": "opportunity:chat/queue", "rule": "opportunity"}),
                     ("harness-y-20260110T000000Z", {"id": "test_slow:repo:test_x", "rule": "test_slow"}),
                     ("llm-z-20260110T000000Z", {"id": "leg-failure:codex/x", "rule": "leg-failure"})):
    T.write_json(os.path.join(work, "doctors", "runs", ref + ".json"), {"problems": [problem]})
for back, wait in ((1, 40), (2, 40), (3, 40), (4, 9000)):
    T.write_json(T.day_cache_path(T.local_day(D0 + back * 86400)),
                 {"settled": True, "seconds": {"suite_wait": wait, "model": 5000}, "worker": {}})
check(night_spend.spend(night, "/usr/bin/false")["hours"] == 2.5,
      "the night report's worker wall starts at each run's pid, not its restamped started_at")
rollout = os.path.join(work, "codex-rollout.jsonl")
lines(rollout, [{"payload": {"type": "token_count", "info": {"total_token_usage": {"input_tokens": 1000,
                                                                                    "output_tokens": 100}}}}])
for resumed in ("codex-1-1-aaaa", "codex-2-2-bbbb"):
    os.makedirs(os.path.join(work, "runs", resumed))
    with open(os.path.join(work, "runs", resumed, "session-file"), "w") as handle:
        handle.write(rollout + "\n")
seen = set()
check([bool(night_spend.weighted(night_spend.run_usage("/usr/bin/false", resumed, "codex", seen)))
       for resumed in ("codex-1-1-aaaa", "codex-2-2-bbbb")] == [True, False],
      "a codex RESUME sharing its session's rollout counts that session's whole total once, not once per run")
out = subprocess.run([sys.executable, os.path.join(root, "share", "time_budget.py"), "night", "/usr/bin/false",
                      os.path.join(nights, "N1.json")], capture_output=True, text=True).stdout.splitlines()
check(out[:6] == ["ledger · night N1 · 3.1 h",
                 "ledger · workers 2.5 h wall · model 1.2 h (49 %) · queued 0.2 h · own tests 0.8 h",
                 "ledger · lines by jobs: code +3/-1 · tests +2/-0 · outside jobs +4/-0",
                 "ledger · rewrote 0 of 1 week-old lines",
                 "ledger · problems 8 → 7 · proved 1 · regressed 0 · touched again without proof 0",
                 "ledger · spend 0.0M · deferred: debt round left"] and max(len(l) for l in out) <= 100,
      "the ledger: duration, worker wall against model, queue and own tests, lines by jobs and outside them, "
      "week-old rewrites, problems, spend and what was deferred, every line in 100 columns: %s" % out[:6])
check(out[6:10] == ["trend · last 2 nights · oldest first",
                  "trend · 09 Jan · 1.8 h · workers ? model · problems 6 → 5 · spend 0.0M · deferred",
                  "trend · 10 Jan · 3.1 h · workers 49 % model · problems 8 → 7 · spend 0.0M · deferred",
                  "trend · problems 6 → 7 over 2 nights · going back"],
      "the trend: one line per night oldest first, an untimed night reads ?, and the direction from the first "
      "night's start to the last night's end, so problems that came between nights count too: %s" % out[6:10])
check(out[10:] == ["roi · harness-x-20260110T000000Z · suite slot wait · 0.0M · +5/-1 lines · saves 1.0 min/day",
                   "roi · harness-y-20260110T000000Z · repo/test_x · 0.0M · +0/-0 lines · not landed",
                   "roi · night: improvements 0.0M · gained 1.0 min/day",
                   "roi · last 2 nights: improvements 0.0M · gained 1.0 min/day"],
      "the ROI ledger: each Speed or time fixer job with its spend, lines and the min/day its class lost less over "
      "up to 3 settled days after a full day of the change than before it; other fixers are no improvement: %s"
      % out[10:])
item = {"class": "suite_wait", "merged": True}
check(T.saved_min_day(item, D0 + 11000, D0 + 86400 * 2.5) is None
      and T.saved_min_day(dict(item, **{"class": "slot"}), D0 + 11000, D0 + 86400 * 9) == 0.0
      and T.roi_lines([{"started": D0, "hours": 3.0, "improvements": [dict(item, ref="r", spend_m=2.0, lines=[1, 1],
                                                                          **{"class": "slot"})]}], D0 + 86400 * 9)
      == ["roi · r · worker slot queue · 2.0M · +1/-1 lines · spend without result",
          "roi · night: improvements 2.0M · gained 0.0 min/day",
          "roi · last 1 nights: improvements 2.0M · gained 0.0 min/day · spend without result so far"],
      "a change pends until it ran a full settled day; no measured gain reads spend without result")
check(T.roi_lines([{"started": D0, "hours": 3.0, "improvements": [dict(item, ref="r", spend_m=2.0, lines=[1, 1])]}],
                  D0 + 86400 * 2.5)[-1] == "roi · last 1 nights: improvements 2.0M · gained 0.0 min/day · nothing measured yet",
      "while every change still pends the cumulative line says nothing was measured, never spend without result")
shown = T.roi_lines([{"started": D0, "hours": 3.0, "improvements": [dict(item, ref="r", spend_m=2.0, lines=[1, 1],
                                                                        **{"class": None})]}], D0 + 86400 * 2.5)
check(shown[0] == "roi · r · harness total · 2.0M · +1/-1 lines · pending a full day",
      "an improvement whose class is None measures the harness total, never crashes the ROI lines: %s" % shown)
L = D0 + 20 * 86400 + 43200
for back in (1, 2, 3):
    T.write_json(T.day_cache_path(T.local_day(L - back * 86400)), {"settled": True, "seconds": {"slot": 0, "model": 0}, "worker": {}})
    T.write_json(T.day_cache_path(T.local_day(L + back * 86400)),
                 {"settled": True, "seconds": {"slot": 60, "model": 5000}, "worker": {}})
check(T.saved_min_day(dict(item, **{"class": "slot"}), L, L + 86400 * 9) == T.UNMEASURED
      and T.roi_lines([{"started": L, "hours": 3.0, "improvements": [dict(item, ref="r", spend_m=2.0, lines=[1, 1],
                                                                         **{"class": "slot"})]}], L + 86400 * 9)
      == ["roi · r · worker slot queue · 2.0M · +1/-1 lines · unmeasured before or after it",
          "roi · night: improvements 0.0M · gained 0.0 min/day · 1 unmeasured",
          "roi · last 1 nights: improvements 0.0M · gained 0.0 min/day"],
      "days stored as zeros before measurement started are unmeasured: the ROI settles as unmeasured, never pending, "
      "and its spend stays out of the return")
measure = dict(item, ref="r", spend_m=2.0, lines=[1, 1], ids=["opportunity:time/slot"], files=[
    ["llm-legs", "bin/speed-doctor"], ["llm-legs", "share/harness-ledger.json"], ["llm-legs", "tests/test_x.sh"],
    ["llm-legs", "docs/x.md"]], **{"class": "slot"})
check(T.roi_lines([{"started": D0, "hours": 3.0, "improvements": [measure]}], D0 + 86400 * 9)
      == ["roi · r · worker slot queue · 2.0M · +1/-1 lines · measurement fix",
          "roi · night: improvements 2.0M · gained 0.0 min/day · 1 measurement fix",
          "roi · last 1 nights: improvements 2.0M · gained 0.0 min/day · nothing measured yet"],
      "a fix whose commits changed only a measurer, a ledger, tests or docs is a measurement fix, never a gain")
suite = lambda files, ids=("suite_audit:llm-legs:test_gate",): T.runtime_change(
    {"class": "suite_run", "ids": list(ids), "files": [["llm-legs", f] for f in files]})
check(suite(["share/suite_audit.py", "tests/test_suite_audit.sh", "share/spend-ledger.json"]) is False
      and suite(["tests/test_suite_audit.sh", "tests/test_gate.sh"]) is True
      and suite(["tests/gate_harness.sh"]) is True
      and suite(["share/suite_audit.py"], ["suite_audit:llm-legs:test_suite_audit"]) is True
      and suite(["tests/test_other.sh"], ["opportunity:chat/tests"]) is True
      and T.runtime_change(dict(measure, files=measure["files"] + [["llm-legs", "bin/worker-run"]])) is True
      and T.runtime_change(dict(measure, files=None)) is None,
      "runtime code of a unit: any code but measurers, ledgers and docs; tests only for a suite unit, and only its "
      "named suite, test helpers, or a measurer for the measurer's own suite")
empty = T.document(L + 86400 * 9, write=False)
check(empty["total_min"] == 0 and empty["floors"] == [] and empty["lost_min_day"] is None,
      "a window with no recorded time is unmeasured, so it owes no floor: %s %s" % (empty["floors"], empty["lost_min_day"]))
cached = json.load(open(os.path.join(work, "doctors", "night-ledger", "N1.json")))
check(cached["wall_s"] == 9000 and cached["split_s"]["slot"] == 600,
      "a finished night's ledger row is cached, so its numbers outlive the pruned run and event stores")
check(cached["improvements"][0]["files"] == [["repo", "code.py"], ["repo", "tests/test_x.sh"]],
      "a night's ledger row records the files each improvement's commits changed: %s" % cached["improvements"])
for each in cached["improvements"]:
    del each["files"]
with open(T.ledger_cache("N1"), "w") as handle:
    json.dump(cached, handle)
T.cached_row("/usr/bin/false", os.path.join(nights, "N1.json"))
cached = json.load(open(T.ledger_cache("N1")))
check(cached["improvements"][0]["files"] == [["repo", "code.py"], ["repo", "tests/test_x.sh"]]
      and cached["improvements"][1]["files"] == [],
      "a cached row from before files were recorded gets them from its night's commits, its numbers kept")
with open(T.ledger_cache("N1"), "w") as handle:
    json.dump(dict(cached, split_s=dict(cached["split_s"], model=1200, walled=5000)), handle)
check(T.last_night() == {"id": "N1", "wall_s": 5800, "model_s": 1200, "share": 0.207},
      "the last night's worker activity is the newest finished night's cached ledger row, its usage-wall relaunches "
      "outside the wall: %s" % T.last_night())
moved =os.path.join(work, "moved-doctors")
shutil.copytree(os.path.join(work, "doctors"), moved)
shutil.rmtree(os.path.join(moved, "night-ledger"))
env = dict(os.environ)
env.pop("DOCTORS_DIR")
subprocess.run([sys.executable, os.path.join(root, "share", "time_budget.py"), "night", "/usr/bin/false",
                os.path.join(moved, "nights", "N1.json")], capture_output=True, env=env)
check(os.path.exists(os.path.join(moved, "night-ledger", "N1.json"))
      and not os.path.exists(os.path.join(work, "home", ".cache", "doctors")),
      "with no DOCTORS_DIR a night's ledger row is cached in the doctors directory its runs are read from")
for name, meta in (("claudeb-%d-3-cccc" % (D0 + 2000), {"review_round": "R1", "pid_started_at": D0 + 2000,
                                                         "cli_starts": [D0 + 2001], "ended_at": D0 + 2600}),
                   ("claudeb-%d-4-dddd" % (D0 + 3000), {"walled_accounts": ["com"], "pid_started_at": D0 + 3000,
                                                         "cli_starts": [D0 + 3100, D0 + 3300], "ended_at": D0 + 3500})):
    os.makedirs(os.path.join(work, "runs", name))
    for file, body in (("launcher", "launcher-1\n"), ("meta.json", json.dumps(dict(meta, vendor="claudeb")))):
        with open(os.path.join(work, "runs", name, file), "w") as handle:
            handle.write(body)
split = T.night_split(night)[1]
check(round(split["review"]) == 600 and round(split["walled"]) == 200 and round(split["retries"]) == 400,
      "a night run's meta.json names its review round and usage walls as review_round and walled_accounts: %s"
      % dict(split))
print(count[0])
EOF
) || exit 1
printf 'PASS: test_time_budget.sh (%s asserts)\n' "$asserts"
