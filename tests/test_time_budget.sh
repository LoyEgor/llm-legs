#!/usr/bin/env bash
. "${BASH_SOURCE%"${BASH_SOURCE##*/}"}lib/suite-journal.sh"
# share/time_budget.py: one worker run's wall split from its pid start (never the restamped started_at), each class
# the union of its spans and the overhead the union of all, the day history, the night ledger line with its trend and
# cache, and the daily problem-count rows of share/collector_runs.py. Fixture stores only.
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
WORK="$(cd -P "$(mktemp -d)" && pwd)"
trap 'rm -rf "$WORK"' EXIT
export TZ=UTC HOME="$WORK/home" HARNESS_DOCTOR_DIR="$WORK/harness" DOCTORS_DIR="$WORK/doctors" \
  WORKER_STATS_DIR="$WORK/stats" WORKER_RUN_DIR="$WORK/runs" RUN_SUITES_JOURNAL="$WORK/suites.jsonl" \
  INSTRUCTION_WATCH_STATE="$WORK/watch" NIGHT_RUN_SWEEP_REPOS="$WORK/sweep-repos" \
  GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
unset HARNESS_WAITS_DIR XDG_CACHE_HOME RUN_SUITES_TIMES CLAUDEB_DIR CHAT_NAME_ROOTS
mkdir -p "$HOME"

D0=1768003200
REPO="$WORK/repo"
git init -q "$REPO"
commit() { # epoch message
  GIT_AUTHOR_DATE="@$1" GIT_COMMITTER_DATE="@$1" git -C "$REPO" -c user.name=t -c user.email=t@t commit -qam "$2"
}
printf 'a\nb\n' >"$REPO/code.py"
git -C "$REPO" add code.py
GIT_AUTHOR_DATE="@$((D0 - 864000))" GIT_COMMITTER_DATE="@$((D0 - 864000))" \
  git -C "$REPO" -c user.name=t -c user.email=t@t commit -qm base
mkdir -p "$REPO/tests"
printf 'A\nb\nc\nd\n' >"$REPO/code.py"
printf 'x\ny\n' >"$REPO/tests/test_x.sh"
git -C "$REPO" add tests/test_x.sh
commit $((D0 + 500)) "Night job"
JOB=$(git -C "$REPO" rev-parse --short=7 HEAD)
printf '1\n2\n3\n4\n' >"$REPO/other.txt"
git -C "$REPO" add other.txt
commit $((D0 + 900)) "Day work"
echo "$REPO" >"$WORK/sweep-repos"

asserts=$(python3 - "$ROOT" "$WORK" "$D0" "$JOB" <<'EOF'
import collections, contextlib, io, json, os, shutil, subprocess, sys, time

root, work, D0, job = sys.argv[1], sys.argv[2], float(sys.argv[3]), sys.argv[4]
sys.path.insert(0, os.path.join(root, "share"))
import collector_runs
import night_spend
import re
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
    ["c", D0 + 3000, "p", "Bash", 0, 3000, "w", "tid0000004", "abcd1234", 1],
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
check(T.length(cost["spans"]) == 348, "overlapping retries are charged once in the wall partition")
check(T.refusal_cost(D0 + 115, D0 + 125, recovery_events)["seconds"] == 5,
      "recovery intervals are clipped at both reporting window boundaries")
for row in recovery_events["t"]:
    row.extend(["n", [0, 0, 0], 0, [], [], {"gen": row[3] - row[1]}, {}, []])
recovery_events["t"].append(["t", D0 + 90, "recover1", D0 + 150, "n", [0, 0, 0], 0, [], [],
                              {"gen": 60}, {}, []])
def budget_on(lo, hi, events):
    real, T.event_rows = T.event_rows, lambda *args, **kwargs: events
    try:
        return T.budget(lo, hi)
    finally:
        T.event_rows = real
charged = budget_on(D0, D0 + 86400, recovery_events)
check(charged["seconds"]["refusal"] == 348, "measured recovery is its own class, retries charged once")
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
      and extra_cost["seconds"] == 20 and extra_cost["count"] == 2,
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
      and extra_cost["by_gate_s"]["unknown-hook"] == 11 and extra_cost["seconds"] == 21,
      "profile subagent transcripts use the parent session, deduplicate copied calls and retain unnamed hooks")
os.unlink(profile)
os.unlink(transcript)
probe_gates, probe_run = os.path.join(work, "probe-gates.jsonl"), "claudeb-%d-9-pppp" % (D0 + 400)
lines(probe_gates, [{"at": D0 + 510, "sid": "fixer123-full", "gate": "worker-pin-gate.sh", "decision": "denied",
                     "tool_use_id": "probe1"},
                    {"at": D0 + 511, "sid": "chat9999-full", "gate": "english-gate.sh", "decision": "denied",
                     "tool_use_id": "chat1"}])
os.makedirs(os.path.join(night_spend.RUNS, probe_run))
with open(os.path.join(night_spend.RUNS, probe_run, "session"), "w") as handle:
    handle.write("fixer123-0000\n")
real_stats, T.gates_path = os.environ["WORKER_STATS_DIR"], lambda: probe_gates
os.environ["WORKER_STATS_DIR"] = os.path.join(work, "probe-stats")
lines(os.path.join(work, "probe-stats", "runs.jsonl"), [
    {"run": probe_run, "ended_at": D0 + 600, "workdir": "/p/.claude/worktrees/night-20260110T000000Z-aaaa-harness-x"},
    dict(run, workdir="/p")])
probe_cost = T.refusal_cost(D0 + 490, D0 + 530, {"c": [call(509, "probe1", "fixer123"), call(518, "after1", "fixer123"),
                                                       call(510, "chat1", "chat9999"), call(514, "after2", "chat9999")]})
check(probe_cost["by_gate_s"] == {"english-gate.sh": 3} and probe_cost["count"] == 1 and probe_cost["probe_s"] == 8
      and probe_cost["probes"] == 1, "a night worker's denial (fixers probe the gates they fix) is no lost time: its "
      "recovery sums apart as probe seconds: %s" % probe_cost)
os.environ["WORKER_STATS_DIR"], T.gates_path = real_stats, lambda: fixture
resumed = os.path.join(work, "home", ".claude", "projects", "fixture", "resume1-full.jsonl")
denial = lambda t, tid: {"timestamp": iso(D0 + t), "message": {"content": [
    {"type": "tool_result", "tool_use_id": tid, "is_error": True, "content": "PreToolUse:Bash hook error: [cd-guard.sh] x"}]}}
lines(resumed, [{"timestamp": iso(D0 + 400), "type": "user"}, denial(500, "resume1")])
resumed_ids = lambda: [r["tool_use_id"] for r in T.refusal_rows(D0 + 490, D0 + 530) if r["sid"].startswith("resume1")]
resumed_ids()
T.save_refusals()
T._REFUSALS.clear()
T._REFUSALS_HELD.clear()
with open(resumed, "rb") as handle:
    text = handle.read()
with open(resumed, "wb") as handle:
    handle.write(text.replace(b"hook error", b"hook_error") + (json.dumps(denial(510, "resume2")) + "\n").encode())
check(resumed_ids() == ["resume1", "resume2"],
      "a transcript scan resumes at the last run's byte: refusals read before are never parsed again")
with open(resumed, "wb") as handle:
    handle.write(text.replace(b"user", b"usex").replace(b"hook error", b"hook_error"))
check(resumed_ids() == [], "a transcript whose first bytes changed was replaced and is read whole")
os.unlink(resumed)
blocks =os.path.join(work, "home", ".claude", "projects", "fixture", "recover5-full.jsonl")
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
check(blocked["by_gate_s"] == {"ask-span-drill.sh": 20, "unknown-posttooluse-hook": 10, "unknown-stop-hook": 300}
      and blocked["count"] == 3 and blocked["unmeasured_by_gate"] == {} and blocked["seconds"] == 330,
      "a Stop block recovers until its turn ends, a PostToolUse block until the next call, a copied block counts once, "
      "and a block whose next call comes after the cap costs the cap, never zero: %s" % blocked)
os.unlink(blocks)
T.gates_path = old_gates
baseline = budget_on(D0, D0 + 86400, recovery_events)
check(round(charged["overhead_s"] - baseline["overhead_s"]) == 348 and baseline["seconds"]["refusal"] == 0,
      "measured recovery adds its own union to the overhead, once: %s" % (charged["overhead_s"] - baseline["overhead_s"]))


def run_dir(run, files):
    folder = os.path.join(work, "runs", run)
    shutil.rmtree(folder, ignore_errors=True)
    os.makedirs(folder)
    for name, body in files.items():
        with open(os.path.join(folder, name), "w") as handle:
            handle.write(body)


L = lambda split: {k: round(T.length(v)) for k, v in split.items() if T.length(v)}
calls = T.event_rows(D0, D0 + 86400)["c"]
split = T.run_split(run, 0, 1e12, T.suite_rows(0, 1e12), calls)
check(L(split) == {"slot": 600, "retries": 400, "suite_wait": 1000, "suite_run": 2000, "tools": 600, "model": 4400},
      "a worker run's wall starts at its pid, not the restamped started_at: slot queue, retries, its own suites "
      "(the call inside them absorbed), its tools, the rest model: %s" % L(split))
background = T.run_split(run, 0, 1e12, T.suite_rows(0, 1e12), [c for c in calls if c[7] != "tid0000004"])
check(L(background) == {"slot": 600, "retries": 400, "suite_run": 300, "tools": 600, "model": 7100},
      "a suite outside every call of its run ran in the background: the run generated beside it, so only the call "
      "waiting on it is suite time: %s" % L(background))
walled = T.run_split(dict(run, walled=["com"]), 0, 1e12, T.suite_rows(0, 1e12), calls)
check(L(walled) == {"slot": 600, "walled": 400, "suite_wait": 1000, "suite_run": 2000, "tools": 600, "model": 4400},
      "a walled run's earlier attempts are weather, neither retries nor work: %s" % L(walled))
bench = T.run_split(dict(run, workdir="/w/logo-vectorizer-bench/lane"), 0, 1e12, T.suite_rows(0, 1e12), calls)
check(L(bench) == {"bench": 9000}, "a bench worker is its own class, whole: %s" % L(bench))
clipped = T.run_split(run, D0 + 5000, D0 + 7300, T.suite_rows(0, 1e12), [])
orphan = T.run_split(dict(run, run="claudeb-1-9-none"), 0, 1e12, [], [])
check(L(clipped) == {"suite_run": 1000, "model": 1300} and L(orphan) == {"slot": 600, "retries": 400, "other": 8000},
      "a window clips every span, and a run with no session file is unsplit, never model: %s %s" % (L(clipped), L(orphan)))
late = T.run_split(run, D0 + 7700, D0 + 10000, T.suite_rows(0, 1e12),
                   calls + [["c", D0 + 8500, "p", "Bash", 0, 200, "w", "tid0000009", "abcd1234", 1]])
check(L(late) == {"tools": 200, "model": 2100}, "a call outside the window stays out of its tool time: %s" % L(late))
WS = "claudeb-%d-9-wsss" % (D0 + 1000)
run_dir(WS, {"worker-session": "ws000001-0000\n"})
check(T.run_session(WS) == "ws000001" and "other" not in L(T.run_split(dict(run, run=WS), 0, 1e12, [], [])),
      "a run whose CLI session only worker-session names (gemini, codex) is split, never unmeasured")

day = T.budget(D0, D0 + 86400)
check(day["seconds"] == dict(dict.fromkeys(T.LABEL, 0), suite_run=2100, suite_wait=1000, slot=601, retries=400,
                             hooks=100, stop=20, locks=40, holds=45, other=649)
      and day["active_s"] == 9000 and day["runs"] == 2
      and {k: day["rows"][k] for k in ("tests", "waiting for workers", "hooks and gates", "unmeasured")}
      == {"tests": 3100, "waiting for workers": 1001, "hooks and gates": 160, "unmeasured": 649},
      "each class is the union of its spans: suites from every caller, a review round's slot queue too, hook rows and "
      "a turn's Stop seconds at its end, locks a chat paid (a background job's never), a review launch held whoever "
      "paid it, a review round's unsplit rest "
      "and a turn's unexplained seconds unmeasured; a row is the union of its classes: %s %s"
      % (day["seconds"], day["rows"]))
TWIN = "claudeb-%d-8-twin" % (D0 + 1000)
run_dir(TWIN, {"session": "twin0001-0000\n"})
lines(os.path.join(work, "twin-stats", "runs.jsonl"), [run, review, dict(run, run=TWIN)])
os.environ["WORKER_STATS_DIR"] = os.path.join(work, "twin-stats")
pair = T.budget(D0, D0 + 86400)
os.environ["WORKER_STATS_DIR"] = os.path.join(work, "stats")
check(pair["runs"] == 3 and pair["rows"]["waiting for workers"] == day["rows"]["waiting for workers"]
      and pair["overhead_s"] == day["overhead_s"],
      "two runs queued and retried side by side count once: %s %s" % (pair["rows"], pair["overhead_s"]))
check(day["overhead_s"] == 4290 and sum(day["seconds"].values()) == 4955,
      "the overhead is the union of all classes, a second two classes share counted once, never their sum: %s"
      % day["overhead_s"])
check(day["strata"] == {"chat": {"overhead_s": 60, "holds_s": 0, "units": 0},
                        "workers": {"overhead_s": 4101, "holds_s": 0, "units": 2},
                        "night": {"overhead_s": 0, "holds_s": 0, "units": 0}, "out_s": {"suites": 100, "unmeasured": 649}},
      "a chat's stratum holds its turns' Stop seconds and the locks it paid, a notification turn adds no order; a "
      "worker's holds its own classes and the hook its call ran; a suite of no worker and no chat with turns and the "
      "unmeasured seconds stay out, reported: %s" % day["strata"])
T.write_json(T.day_cache_path("2026-01-10"), {"settled": True, "seconds": {"model": 5000}, "worker": {}})
later = D0 + 3 * 86400 + 3600
recomputed = T.history(later, True, 5.0)
check(recomputed == {"2026-01-10": 71.5, T.local_day(later): 5.0}
      and json.load(open(T.day_cache_path("2026-01-10")))["version"] == T.BUDGET_VERSION,
      "a settled day an older budget cached is recomputed and stored again; the history holds each measured day's "
      "overhead and today's latest value: %s" % recomputed)
T.write_json(T.day_cache_path("2026-01-10"), dict(json.load(open(T.day_cache_path("2026-01-10"))), overhead_s=600))
check(T.history(later, True, 5.0)["2026-01-10"] == 10.0, "a day the current budget settled is read, never recomputed")
os.unlink(T.day_cache_path("2026-01-10"))

NOW = D0 + 20 * 3600
doc = T.document(NOW)
check(doc["refusal_cost"]["unmeasured_by_gate"] == {"unknown": 1} and doc["refusal_cost"]["min_day"] == 0
      and doc["refusals"] == 1 and doc["worker_runs"] == 2,
      "JSON reports the refusal count and its cost coverage")
check(doc["lost_min_day"] == 71.5 and doc["lines"][0] == "52 min/day tests · running 35 · queued 17" and doc["rows"] == [
          [51.7, "tests", [[35.0, "running"], [16.7, "queued"]]],
          [16.7, "waiting for workers", [[10.0, "worker queue"], [0.0, "wrap-up"], [6.7, "retries"], [0.0, "dead, hung"]]],
          [10.8, "unmeasured", []],
          [2.7, "hooks and gates", [[2.0, "hooks"], [0.0, "gate refusals"], [0.7, "locks"], "-", [1.7, "gate"]]],
          [0.8, "limiter holds", [[0.8, "review-cells"]]], [0.0, "usage walls", []], [0.0, "compaction", []], "-", [150.0, "system active", []]],
      "the day document: each row with its parts, gates and the heaviest hooks under theirs, by size the first day "
      "seen, system active last: %s" % doc["rows"])
check("tests" not in doc and not any(l.startswith("Tests:") for l in doc["lines"]),
      "test time is share/test_health.py's block, never a second line here")

DEAD = "claudeb-%d-5-dddd" % (D0 + 30000)
dead_row = {"run": DEAD, "status": "failed", "round": None, "pid_started_at": D0 + 30000, "started_at": D0 + 30000,
            "cli_starts": [D0 + 30010], "ended_at": D0 + 30610, "workdir": "/w/feat"}
dead_files = {"session": "dead0001-aaaa", "worker-session": "dead0001-aaaa", "files": "WORKDIR: /w/feat\n",
              "head-before": "abc\n", "head-after": "abc\n", "files-external": "",
              "result": "Failed to authenticate: OAuth session expired and could not be refreshed\n",
              "brief": "EFFORT: low\n\nRESUME dead0001-aaaa: its own resume is no continuation\n"}
run_dir(DEAD, dead_files)
check(T.dead_runs([dead_row]) == {DEAD}
      and L(T.run_split(dict(dead_row, dead=True), 0, 1e12, [], [])) == {"slot": 10, "dead": 600},
      "a failed run nobody resumed, with no file, commit or report, is dead: its last attempt's wall, the slot queue "
      "before it kept apart")
run_dir(DEAD, dict(dead_files, result="You've hit your 5-hour limit · resets 6:20am\n"))
check(T.dead_runs([dead_row]) == {DEAD},
      "Claude Code 2.1.312's wall line, \"5-hour limit\" where it said \"session limit\", is a dead run's line")
run_dir(DEAD, dead_files)
alive = {"files names a path": dict(dead_files, files="WORKDIR: /w/feat\nsrc/a.py\n"),
         "files partial": dict(dead_files, files="WORKDIR: /w/feat\nPARTIAL: the run also ran shell commands\n"),
         "files unknown": dict(dead_files, files="UNKNOWN: the workdir after snapshot could not be established\n"),
         "no files record": {k: v for k, v in dead_files.items() if k != "files"},
         "head moved": dict(dead_files, **{"head-after": "def\n"}),
         "no head after": {k: v for k, v in dead_files.items() if k != "head-after"},
         "wrote outside": dict(dead_files, **{"files-external": "/tmp/x\n"}),
         "a report": dict(dead_files, result="Failed to authenticate.\nDone: the fixture passes, 3 files read\n"),
         "a long error": dict(dead_files, result="API Error: " + "x" * 400 + "\n")}
kept = [why for why, files in alive.items() if run_dir(DEAD, files) or T.dead_runs([dead_row])]
run_dir(DEAD, dead_files)
check(kept == [] and T.dead_runs([dict(dead_row, status="done")]) == T.dead_runs([dict(dead_row, round=2)])
      == T.dead_runs([dict(dead_row, workdir="/w/logo-vectorizer-bench")]) == set(),
      "a changed file, an unknown or partial listing, a missing record, a moved HEAD, a write "
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
check(died["seconds"]["dead"] == 600 and died["dead_runs"] == [DEAD] and died["rows"]["waiting for workers"] == 610,
      "dead worker runs are a waiting-for-workers class: %s" % died["seconds"])

queue_turn = ["t", D0 + 3950, "sessQ", D0 + 4400, "n", [0, 0, 0], 0, [], [], {"gen": 50, "queue": 300, "test": 100},
              {}, []]
chat_journal = os.path.join(work, "chat-suites.jsonl")
lines(chat_journal, list(night_spend.rows(os.environ["RUN_SUITES_JOURNAL"]))
      + [{"kind": "direct", "queued_at": D0 + 4000, "started_at": D0 + 4300, "ended_at": D0 + 4400, "worker_run": None,
          "session": "sessQ", "suites": {"test_a.sh": {"rc": 0, "secs": 100}}}])
os.environ["RUN_SUITES_JOURNAL"], journal = chat_journal, os.environ["RUN_SUITES_JOURNAL"]
queued = budget_on(D0, D0 + 86400, {"t": [queue_turn], "c": [], "h": []})
os.environ["RUN_SUITES_JOURNAL"] = journal
check(queued["seconds"]["suite_wait"] == 1300 and queued["seconds"]["suite_run"] == 2100,
      "a chat's suite queue is suite slot wait from run-suites' journal, and its run inside a worker's suite counts "
      "once: %s" % queued["seconds"])

wrapped = T.run_split(dict(run, attempt_secs=[300, 7000]), 0, 1e12, T.suite_rows(0, 1e12), calls)
unpaired = T.run_split(dict(run, attempt_secs=[7000]), 0, 1e12, T.suite_rows(0, 1e12), [])
check(L(wrapped)["wrapup"] == 1000 and L(wrapped)["model"] == 3400 and sum(L(wrapped).values()) == 9000
      and not unpaired["wrapup"],
      "the last CLI's exit -> the run's end is wrap-up, not model; with attempts and their seconds unpaired it is "
      "unknown and stays in the run: %s" % L(wrapped))
with open(os.path.join(work, "runs", RUN, "killed"), "w") as handle:
    handle.write("idle 1800\n")
hung_split = {reason: L(T.run_split(dict(run, attempt_secs=[300, 7000], reason=reason), 0, 1e12, T.suite_rows(0, 1e12),
                                    calls))
              for reason in ("idle", "deadline")}
with open(os.path.join(work, "runs", RUN, "killed"), "w") as handle:
    handle.write("silent\n")
silent = L(T.run_split(dict(run, attempt_secs=[300, 7000], reason="silent"), 0, 1e12, T.suite_rows(0, 1e12), []))
os.remove(os.path.join(work, "runs", RUN, "killed"))
check(hung_split["idle"]["hung"] == 1800 and hung_split["idle"]["tools"] == 200
      and sum(hung_split["idle"].values()) == 9000 and "hung" not in hung_split["deadline"]
      and silent["hung"] == 7000 and "suite_run" not in silent and "model" not in silent,
      "a watchdog's idle kill books its idle seconds before the exit as hung, a silent kill the whole last attempt; a "
      "deadline kill has no idle stamp and stays work: %s %s" % (hung_split["idle"], silent))
lines(os.path.join(work, "tail-stats", "runs.jsonl"), [dict(run, attempt_secs=[300, 7000])])
os.environ["WORKER_STATS_DIR"] = os.path.join(work, "tail-stats")
tail = T.budget(D0, D0 + 86400)
os.environ["WORKER_STATS_DIR"] = os.path.join(work, "stats")
check(tail["seconds"]["wrapup"] == 1000 and tail["rows"]["waiting for workers"] == 2000,
      "a wrap-up tail is a waiting-for-workers class: %s" % tail["rows"])
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
saved = {k: os.environ.pop(k, None) for k in ("DOCTORS_DIR", "LLM_DOCTOR_DIR")}
os.environ["LLM_DOCTOR_DIR"] = os.path.join(work, "llm")
collector_runs.problem_day("llm", {"problem_count": 5}, "LLM_DOCTOR_DIR")
os.environ["SPEED_DOCTOR_DIR"] = os.path.join(work, "speed")
collector_runs.record("speed", time.time())
del os.environ["LLM_DOCTOR_DIR"], os.environ["SPEED_DOCTOR_DIR"]
os.environ.update({k: v for k, v in saved.items() if v is not None})
check(not os.path.exists(os.path.join(work, "home", ".cache", "doctors")),
      "a fixture doctor directory with no DOCTORS_DIR never reaches the default journal, a problem day nor a run")
# A doctor exec'd by another journals its own CPU: the base handed across execv is subtracted.
exec_runs = os.path.join(work, "exec-runs")
for base in ("", "1e6"):
    subprocess.run([sys.executable, "-c", "import sys, time; sys.path.insert(0, sys.argv[1]); import collector_runs; "
                    "collector_runs.record('speed', time.time())", os.path.join(root, "share")],
                   env=dict(os.environ, DOCTORS_DIR=exec_runs, DOCTOR_CPU_BASE=base), check=True)
cpu = [json.loads(line)["cpu_s"] for line in open(os.path.join(exec_runs, "collector-runs.jsonl"))]
check(cpu[0] > 0 and cpu[1] == 0, "a run's cpu_s is its CPU less the inherited DOCTOR_CPU_BASE: %s" % cpu)

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
for ref, problem in (("harness-x-20260110T000000Z", {"id": "opportunity:time/wrapup", "rule": "opportunity"}),
                     ("harness-y-20260110T000000Z", {"id": "test_slow:repo:test_x", "rule": "test_slow"}),
                     ("llm-z-20260110T000000Z", {"id": "leg-failure:codex/x", "rule": "leg-failure"})):
    T.write_json(os.path.join(work, "doctors", "runs", ref + ".json"), {"problems": [problem]})
for back, wait in ((-3, 100), (-2, 100), (-1, 100), (1, 40), (2, 40), (3, 40), (4, 9000)):
    T.write_json(T.day_cache_path(T.local_day(D0 + back * 86400)),
                 {"settled": True, "version": T.BUDGET_VERSION, "seconds": {"wrapup": wait}, "overhead_s": wait, "active_s": 5000})
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
long_rollout = os.path.join(work, "codex-long-rollout.jsonl")
lines(long_rollout, [{"payload": {"type": "token_count", "info": {"total_token_usage": {"input_tokens": 9000 - n,
                                                                                         "output_tokens": 900}}}}
                     for n in range(300)] + [{"payload": {"type": "token_count", "info": None}}, {"payload": {}}])
kept_parsed, read_rows = night_spend.parsed, [0]


def counted(lines):
    for row in kept_parsed(lines):
        read_rows[0] += 1
        yield row


night_spend.parsed = counted
tail_usage = night_spend.codex_usage(long_rollout, None)
night_spend.parsed = kept_parsed
check(tail_usage == night_spend.vendor_eq("codex", None, 8701, 0, 0, 900) and read_rows[0] <= 3,
      "a codex rollout's running total is read off its end, never its whole file: %s rows read" % read_rows[0])
printed = io.StringIO()
with contextlib.redirect_stdout(printed):
    T.main(["night", "/usr/bin/false", os.path.join(nights, "N1.json")])
out = printed.getvalue().splitlines()
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
                  "trend · problems 6 → 7 over 2 nights · last 2: 2 down, 0 up · moving forward"],
      "the trend: one line per night oldest first, an untimed night reads ?, the span from the first night's start "
      "to the last night's end, and the direction from each recent night's own before → after: %s" % out[6:10])
audit = [{"problems": p, "started": D0 + i * 86400, "hours": 1.0, "split_s": {}, "wall_s": 0, "spend_m": 0.0,
          "deferred": ""} for i, p in enumerate([(32, 28), (28, 25), (25, 22), (22, 20), (20, 19), (33, 39), (19, 24)])]
check(T.trend_lines(audit)[-1] == "trend · problems 32 → 24 over 7 nights · last 3: 1 down, 2 up · going back",
      "the trend never reads forward while the recent nights each ended with more problems than they began with: %s"
      % T.trend_lines(audit)[-1])
check(out[10:14] == ["roi · harness-x-20260110T000000Z · worker wrap-up · 0.0M · +5/-1 lines · day totals: unmeasured",
                   "roi · harness-y-20260110T000000Z · repo/test_x · 0.0M · +0/-0 lines · not landed",
                   "roi · night: improvements 0.0M · gained 0.0 min/day · 1 unmeasured",
                   "roi · last 2 nights: improvements 0.0M · gained 0.0 min/day"],
      "the ROI ledger: each Speed or time fixer job with its spend and lines; the 1.0 min/day its class lost less over "
      "up to 3 settled days after a full day of the change than before it has no load control, so it is unmeasured, "
      "never a gain; other fixers are no improvement: %s"
      % out[10:])
check(out[14:] == [], "the reported night's own fixes never reach the morning's «Скорость» block: %s" % out[14:])
item = {"class": "wrapup", "merged": True}
check(T.day_totals_state(item, D0 + 11000, D0 + 86400 * 2.5) is None
      and T.day_totals_state(dict(item, **{"class": "retries"}), D0 + 11000, D0 + 86400 * 9) == T.MEASURED
      and T.roi_lines([{"started": D0, "hours": 3.0, "improvements": [dict(item, ref="r", spend_m=2.0, lines=[1, 1],
                                                                          **{"class": "retries"})]}], D0 + 86400 * 9)
      == ["roi · r · retries and relaunches · 2.0M · +1/-1 lines · day totals: unmeasured",
          "roi · night: improvements 0.0M · gained 0.0 min/day · 1 unmeasured",
          "roi · last 1 nights: improvements 0.0M · gained 0.0 min/day"],
      "a change pends until it ran a full settled day; its day totals then have no load control: unmeasured, its "
      "spend out of the return")
check(T.roi_lines([{"started": D0, "hours": 3.0, "improvements": [dict(item, ref="r", spend_m=2.0, lines=[1, 1])]}],
                  D0 + 86400 * 2.5)[-1] == "roi · last 1 nights: improvements 2.0M · gained 0.0 min/day · nothing measured yet",
      "while every change still pends the cumulative line says nothing was measured, never spend without result")
shown = T.roi_lines([{"started": D0, "hours": 3.0, "improvements": [dict(item, ref="r", spend_m=2.0, lines=[1, 1],
                                                                        **{"class": None})]}], D0 + 86400 * 2.5)
check(shown[0] == "roi · r · harness total · 2.0M · +1/-1 lines · pending a full day",
      "an improvement whose class is None measures the harness total, never crashes the ROI lines: %s" % shown)
early = {"id": "E1", "started": D0, "hours": 3.0, "improvements": [dict(item, ref="r", spend_m=1.0, lines=[1, 1])]}
pend = {"id": "E2", "started": D0 + 86400 * 8, "hours": 3.0,
        "improvements": [dict(item, ref="r2", spend_m=1.0, lines=[1, 1], **{"class": "slot"})]}
tonight = {"id": "T", "started": D0 + 86400 * 8.5, "hours": 3.0,
           "improvements": [dict(item, ref="r3", spend_m=1.0, lines=[1, 1], **{"class": "slot"})]}
morning = lambda rows, at: T.speed_block(rows, (lambda v: (T.roi_lines(rows, at, verdicts=v), v)[1])({}))
verdict = lambda gain, proven, slower, pending=False: {"pending": pending, "gain": gain, "proven": proven, "slower": slower}
won = {"E1": {0: verdict(1.0, True, False)}}
check(morning([early, tonight], D0 + 86400 * 9) == ["Скорость", "  7 d   +0.0 min/day"]
      and T.speed_block([early, tonight], won) == ["Скорость", "  10 Jan   +1.0 min/day   ✓ 1",
                                                                  "  7 d      +1.0 min/day   ✓ 1"]
      and T.speed_block([early, pend, tonight], won) == ["Скорость", "  7 d   +1.0 min/day   ✓ 1"]
      and morning([tonight], D0 + 86400 * 9) == [],
      "the morning's «Скорость»: a row per earlier night whose proofs matured since the night before the reported one "
      "closed, in min/day, then the trend's matured total; one matured before that close only counts in the total, "
      "pending ones nowhere, the reported night never; the day totals' 1.0 min/day has no load control, never a gain")
check(T.speed_block([dict(early, improvements=[]), tonight], {
    "E1": {0: verdict(2.5, True, False), 1: verdict(-0.4, False, True), 2: verdict(9.0, True, False, True)},
    "T": {0: verdict(30.0, True, False)}}) == ["Скорость", "  10 Jan   +2.1 min/day   ✓ 1   ! 1",
                                              "  7 d      +2.1 min/day   ✓ 1   ! 1"],
      "a night's row sums its matured fixes' min/day, counts ✓ proven and ! measured slower (regression rows)")
nights_speed = os.path.join(work, "speed-nights")
os.makedirs(nights_speed)
json.dump({"id": "S1", "started_at": iso(D0), "finished_at": iso(D0 + 10800)}, open(os.path.join(nights_speed, "S1.json"), "w"))
json.dump({"id": "S2", "started_at": iso(D0 + 86400)}, open(os.path.join(nights_speed, "S2.json"), "w"))
kept = T.cached_row, T.now_s
T.cached_row, T.now_s = (lambda worker_run, p: dict(early, id="S1")), (lambda: D0 + 86400 * 9)
first = T.speed_row("/usr/bin/false", os.path.join(nights_speed, "S1.json"))
printed = io.StringIO()
with contextlib.redirect_stdout(printed):
    T.main(["speed", "/usr/bin/false", os.path.join(nights_speed, "S1.json")])
printed = printed.getvalue()
T.cached_row = lambda worker_run, p: None
again = T.speed_row("/usr/bin/false", os.path.join(nights_speed, "S1.json"))
T.now_s = lambda: D0 + 86400 * 9 + T.SPEED_ROW_S
later = T.speed_row("/usr/bin/false", os.path.join(nights_speed, "S1.json"))
running_row = T.speed_row("/usr/bin/false", os.path.join(nights_speed, "S2.json"))
T.cached_row, T.now_s = kept
check(first == {"at": D0 + 86400 * 9, "items": 1, "gain": 0.0, "proven": 0, "slower": 0, "pending": 0}
      and printed == "speed\t0.0\t0\t0\t0\n" and again == first and later["items"] == 0 and running_row is None,
      "the menu's speed row of a finished night: min/day, proven, slower, pending of its fixes over its trend (a day "
      "totals' gain, with no load control, none), read again once SPEED_ROW_S passed, none while the night runs: %s %r"
      % (first, printed))
L = D0 + 20 * 86400 + 43200
for back in (1, 2, 3):
    T.write_json(T.day_cache_path(T.local_day(L - back * 86400)),
                 {"settled": True, "version": T.BUDGET_VERSION, "seconds": {"slot": 0}, "overhead_s": 0, "active_s": 0})
    T.write_json(T.day_cache_path(T.local_day(L + back * 86400)),
                 {"settled": True, "version": T.BUDGET_VERSION, "seconds": {"slot": 60}, "overhead_s": 60, "active_s": 5000})
check(T.day_totals_state(dict(item, **{"class": "slot"}), L, L + 86400 * 9) == T.UNMEASURED
      and T.roi_lines([{"started": L, "hours": 3.0, "improvements": [dict(item, ref="r", spend_m=2.0, lines=[1, 1],
                                                                         **{"class": "retries"})]}], L + 86400 * 9)
      == ["roi · r · retries and relaunches · 2.0M · +1/-1 lines · unmeasured before or after it",
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
kept = (T.night_churn.fixer_spend, T.night_spend.weighted, T.job_changes)
T.night_churn.fixer_spend = lambda night, path, worker_run: ([{"ref": "r", "state": "merged"}], {"r": {"problems": [
    {"id": "opportunity:hooks/gate.sh", "rule": "opportunity"}, {"id": "test_slow:alpha:test_mid", "rule": "test_slow"},
    {"id": "collector:x", "rule": "collector"}]}}, {"r": 3e6}, None)
T.night_spend.weighted, T.job_changes = (lambda usage: usage), (lambda job: ([4, 2], [["alpha", "tests/test_mid.sh"]]))
batch = T.improvements({}, "", "")
T.night_churn.fixer_spend, T.night_spend.weighted, T.job_changes = kept
check([(i["ids"], i["class"], i["spend_m"], i["lines"]) for i in batch]
      == [(["opportunity:hooks/gate.sh"], "hooks", 1.5, [4, 2]), (["test_slow:alpha:test_mid"], "suite_run", 1.5, [4, 2])],
      "a fixer of several Speed rows is one improvement per row, each in its own class with an even share of the spend: %s"
      % batch)
twice, yielded = [dict(item, ref=ref, spend_m=1.0, lines=[1, 1], ids=[]) for ref in ("r1", "r2")], collections.Counter()
check(T.roi_lines([{"started": D0, "hours": 3.0, "improvements": twice[:1]},
                   {"started": D0 + 3600, "hours": 3.0, "improvements": twice[1:]}], D0 + 86400 * 9, yielded)
      == ["roi · r2 · worker wrap-up · 1.0M · +1/-1 lines · day totals: unmeasured",
          "roi · night: improvements 0.0M · gained 0.0 min/day · 1 unmeasured",
          "roi · last 2 nights: improvements 0.0M · gained 0.0 min/day"] and yielded == {},
      "a class-level drop in the day totals credits no fix over the trend, the earliest neither, nor its fixer job in "
      "Speed's yield (night 7b98's machine-contention fix took 152.8 min/day a quieter machine gave): %s" % yielded)
Q = D0 + 40 * 86400 + 43200
for back in (1, 2, 3):
    T.write_json(T.day_cache_path(T.local_day(Q - back * 86400)),
                 {"settled": True, "version": T.BUDGET_VERSION, "seconds": {"slot": 120}, "overhead_s": 120, "active_s": 6000})
    T.write_json(T.day_cache_path(T.local_day(Q + back * 86400)),
                 {"settled": True, "version": T.BUDGET_VERSION, "seconds": {"slot": 60}, "overhead_s": 60, "active_s": 3000})
check(T.day_totals_state(dict(item, **{"class": "slot"}), Q, Q + 86400 * 9) == T.MEASURED,
      "a quieter week after a fix is no gain: the class's seconds per active second, times the active seconds a day "
      "before it")
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
check(empty["lost_min_day"] is None and empty["lines"] == ["Lost time: nothing measured in the last 24 h"],
      "a window with no recorded time is unmeasured, never a zero day: %s" % empty["lines"])
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
check("review" not in split and round(split["slot"]) == 701 and round(split["other"]) == 799
      and round(split["walled"]) == 200 and round(split["retries"]) == 400,
      "a night run's review round splits like any run, its usage walls are named by walled_accounts: %s"
      % dict(split))


def stats(name, rows):
    lines(os.path.join(work, name, "runs.jsonl"), rows)
    os.environ["WORKER_STATS_DIR"] = os.path.join(work, name)
    found = T.budget(D0, D0 + 86400)
    os.environ["WORKER_STATS_DIR"] = os.path.join(work, "stats")
    return found


def quick(run, at):
    return {"run": run, "round": None, "pid_started_at": at, "started_at": at, "cli_starts": [at + 100], "ended_at": at + 1000}


both = stats("par-stats", [quick("claudeb-1-1-par1", D0 + 50000), quick("claudeb-1-2-par2", D0 + 50000)])
apart = stats("seq-stats", [quick("claudeb-1-1-par1", D0 + 50000), quick("claudeb-1-2-par2", D0 + 52000)])
T.INDEX_MIN_UNITS = 1
alike = T.paasche([apart["strata"]] * 7 + [both["strata"]] * 7)
T.INDEX_MIN_UNITS = 20
check(both["strata"]["workers"] == apart["strata"]["workers"] == {"overhead_s": 200, "holds_s": 0, "units": 2}
      and both["overhead_s"] != apart["overhead_s"] and alike["value"] == 1.0 and alike["left_out"] == ["chat"],
      "the same work in parallel or one after another is the same stratum overhead and index 1.00, while the union "
      "differs: %s %s" % (both["strata"], alike))
DEAD2 = "claudeb-%d-5-dead" % (D0 + 30000)
run_dir(DEAD2, dict({k: v for k, v in dead_files.items() if k != "brief"}, session="dead0002-a", **{"worker-session": "dead0002-a"}))
gone = stats("dead2-stats", [dict(dead_row, run=DEAD2)])
check(gone["dead_runs"] == [DEAD2] and gone["strata"]["workers"] == {"overhead_s": 610, "holds_s": 0, "units": 0},
      "a dead run adds no unit; its minutes stay overhead: %s" % gone["strata"])
run_dir("claudeb-1-1-cha1", {"session": "cafe0001-0000\n"})
run_dir("claudeb-1-2-cha2", {"session": "cafe0002-0000\n", "brief": "EFFORT: low\n\nRESUME cafe0001-0000: go on\n"})
chain = stats("chain-stats", [quick("claudeb-1-1-cha1", D0 + 50000), quick("claudeb-1-2-cha2", D0 + 52000)])
check(chain["strata"]["workers"] == {"overhead_s": 200, "holds_s": 0, "units": 1},
      "a resume chain is one task, each run's overhead its own: %s" % chain["strata"])
day1 = {"chat": {"overhead_s": 600, "units": 10}, "workers": {"overhead_s": 3000, "units": 5},
        "night": {"overhead_s": 0, "units": 0}, "out_s": {"suites": 0, "unmeasured": 0}}
twice = {k: {f: 2 * v for f, v in day1[k].items()} for k in day1}
moved = dict(day1, chat={"overhead_s": 240, "units": 4}, workers={"overhead_s": 5400, "units": 9})
thin = dict(moved, chat={"overhead_s": 600, "units": 1})
check(T.paasche([day1] * 7 + [twice] * 7)["value"] == 1.0 and T.paasche([day1] * 7 + [moved] * 7)["value"] == 1.0
      and T.paasche([day1] * 7 + [thin] * 7)["left_out"] == ["chat", "night"]
      and T.paasche([day1] * 7 + [thin] * 7)["value"] == 1.0
      and T.paasche([day1] * 7 + [dict(day1, workers={"overhead_s": 1500, "units": 5})] * 7)["value"] == 0.58,
      "doubled volume is 1.00, units moved between strata at unchanged prices are 1.00, a stratum under 20 units on "
      "a side is left out and named, a cheaper task reads below 1")
hz = os.path.join(work, "hz-harness")
os.makedirs(os.path.join(hz, "events"))
open(os.path.join(hz, "events", "2026-01-10.jsonl"), "w").close()
early = [quick("claudeb-1-%d-hz%02d" % (k, k), D0 - 7 * 86400 + k // 3 * 86400 + 1000 * (k % 3 + 1)) for k in range(42)]
lines(os.path.join(work, "hz-stats", "runs.jsonl"), early)
os.environ.update(WORKER_STATS_DIR=os.path.join(work, "hz-stats"), HARNESS_DOCTOR_DIR=hz)
young, now_ = T.index_history(D0 + 6 * 86400 + 43200, False)
open(os.path.join(hz, "events", "2026-01-03.jsonl"), "w").close()
grown = T.index_history(D0 + 6 * 86400 + 43200, False)[0]
os.environ.update(WORKER_STATS_DIR=os.path.join(work, "stats"), HARNESS_DOCTOR_DIR=os.path.join(work, "harness"))
check(young == {} and now_["value"] is None and now_["prior"] is None
      and now_["window"]["workers"] == [2100, 21] and grown == {"2026-01-16": 1.0},
      "no index while the prior window reaches before the first day both journals record, never a partial one; the "
      "current window's level stands: %s %s %s" % (young, now_, grown))
E = D0 + 2 * 86400
os.environ["HARNESS_WAITS_DIR"] = os.path.join(work, "late-waits")
lines(os.path.join(work, "late-waits", T.local_day(E - 1) + ".jsonl"),
      [{"class": "lock", "source": "x", "started": E - 50, "seconds": 100, "pid": 1, "caller": "late0001"}])
ended = budget_on(E - 100, E, {"h": [["h", E, "p", "PreToolUse", "gate", 100000, "Bash", "tid"]]})
crossed = budget_on(E, E + 3600, {})
del os.environ["HARNESS_WAITS_DIR"]
check(ended["seconds"]["hooks"] == 100 and crossed["seconds"]["locks"] == 50,
      "a hook row is stamped at its end, so its span ends there; a wait begun before midnight keeps its tail in the "
      "next day: %s %s" % (ended["seconds"]["hooks"], crossed["seconds"]["locks"]))
os.environ["HARNESS_WAITS_DIR"] = os.path.join(work, "hold-waits")
HELD = "claudeb-1-1-held"
lines(os.path.join(work, "hold-waits", "2026-01-10.jsonl"),
      [{"class": "image-fanout", "source": "f", "started": D0 + 50050, "seconds": 200, "pid": 1, "caller": HELD},
       {"class": "future-class", "source": "n", "started": D0 + 60000, "seconds": 60, "pid": 2},
       {"class": "workers", "source": "j", "started": D0 + 61000, "seconds": 600, "pid": 3, "caller": HELD}])
held = stats("held-stats", [quick(HELD, D0 + 50000)])
check(held["seconds"]["holds"] == 260 and held["rows"]["limiter holds"] == 260
      and held["holds_by_class"] == {"image-fanout": 200, "future-class": 60}
      and held["strata"]["workers"] == {"overhead_s": 100, "holds_s": 150, "units": 1},
      "every wait class but the split's own (worker queue, suites) is a limiter hold, a class never named before too, "
      "its owner charged only past its other spans: %s %s" % (held["holds_by_class"], held["strata"]["workers"]))
night_held = [{"class": "image-fanout", "source": "f", "started": D0 + 2000, "seconds": 300, "pid": 1, "caller": RUN},
              {"class": "lock", "source": "l", "started": D0 + 2100, "seconds": 400, "pid": 2, "caller": "launcher-1"},
              {"class": "blender", "source": "b", "started": D0 + 4000, "seconds": 100, "pid": 3, "caller": "elsewhere"},
              {"class": "workers", "source": "j", "started": D0 + 5000, "seconds": 600, "pid": 4, "caller": RUN},
              {"class": "poll", "source": "p", "started": D0 + 10900, "seconds": 300, "pid": 5, "caller": RUN}]
lines(os.path.join(work, "hold-waits", "2026-01-10.jsonl"), night_held)
check(T.night_waits(night) == 600,
      "a night's other waits: its sessions' and worker runs' journaled waits but the worker queue and suites, "
      "unioned and clipped to the night: %s" % T.night_waits(night))
del os.environ["HARNESS_WAITS_DIR"]
day2 = dict(day1, workers={"overhead_s": 3000, "holds_s": 3000, "units": 5})
check(T.paasche([day1] * 7 + [day2] * 7)["value"] == 1.83, "the index prices a stratum's holds with its overhead")
# The comparison table's goal rows: token-map's 7-day Doctors share (never recomputed) and the backlog (review
# debt with its change against the night before, Speed's selection) of this night against the two previous
# finished ones, and the nights to plateau at the burn of their P1+P2 rows (P3 never counts) in this night's column.
spend7 = os.path.join(work, "spend-7d.json")
os.environ["TOKENMAP_SPEND_7D"] = spend7
stamp = lambda hours: time.strftime("%Y-%m-%dT%H:%M:%S+00:00", time.gmtime(time.time() - hours * 3600))
seven = lambda hours: json.dump({"generated_at": stamp(hours), "stale_after_hours": 26,
                                 "tree": [{"name": "Workers", "share": 0.5}, {"name": "Doctors", "share": 0.229}]},
                                open(spend7, "w"))
seven(1)
check(night_spend.doctors_share() == {"share": 22.9}, "the Doctors node's share in %%: %s" % night_spend.doctors_share())
seven(30)
check(night_spend.doctors_share() == {"share": 22.9, "age_h": 30}, "a stale file keeps its share and names its age")
debt = os.path.join(work, "review-debt")
with open(debt, "w") as handle:
    handle.write("#!/bin/sh\nprintf 'LINES=7 FILES=3 DUE_LINES=2 DUE_FILES=1\\n'\n")
os.chmod(debt, 0o755)
os.environ["NIGHT_RUN_REVIEW_DEBT"] = debt
for name, count_ in zip(("llm", "harness", "updater", "code", "system"), (1, 2, 0, 3, 0)):
    os.environ[name.upper() + "_DOCTOR_DIR"] = os.path.join(work, "goal-" + name)
    os.makedirs(os.path.join(work, "goal-" + name), exist_ok=True)
    doc = {"problem_count": count_}
    if name == "harness":
        doc["speed"] = {"selection": ["a", "b", "c"]}
        doc["problems"] = [{"id": "h%d" % i, "rule": "hook-error", "state": "new"} for i in range(6)] + [
            {"id": "s", "rule": "suite_audit", "state": "watch", "speed": True, "value": 0.2, "unit": "wall-min/day"}]
    json.dump(doc, open(os.path.join(work, "goal-" + name, "latest.json"), "w"))
check(night_spend.backlog() == {"debt": 7, "speed": 3}, "backlog now: %s" % night_spend.backlog())
goal_dir = os.path.join(work, "goal-nights")
os.makedirs(goal_dir)
for id_, day, backlog_, share in (("n9", 30, {"debt": 25}, None),
                                  ("n1", 1, {"debt": 20, "speed": 5, "p12": 9}, 30.0),
                                  ("n2", 2, {"debt": 14, "speed": 4, "p12": 8}, 26.5)):
    json.dump({"id": id_, "started_at": "2026-%s:00:00Z" % ("09-30T02" if day == 30 else "10-0%dT02" % day),
               "finished_at": "2026-%s:00:00Z" % ("09-30T08" if day == 30 else "10-0%dT08" % day),
               "jobs": [{"ref": "x"}], "doctors_share": share and {"share": share}, "backlog": backlog_},
              open(os.path.join(goal_dir, id_ + ".json"), "w"))
json.dump({"id": "n0", "finished_at": "2026-09-30T08:00:00Z", "jobs": [{"ref": "x"}]}, open(os.path.join(goal_dir, "n0.json"), "w"))
seven(1)
running = {"id": "n3", "started_at": "2026-10-03T02:00:00Z", "jobs": []}
json.dump(running, open(os.path.join(goal_dir, "n3.json"), "w"))
kept_row = T.cached_row
mixes = {"n1": {"opus": 96.4, "vs_opus": 0.962}, "n2": {}, "n3": {"opus": 85.2, "vs_opus": 0.387}}
T.cached_row = lambda worker_run, path: {"model_mix": mixes[os.path.basename(path)[:-5]]}


def table():
    shown = T.table_lines("/usr/bin/false", os.path.join(goal_dir, "n3.json"))
    return shown, {re.split(" {3,}", l)[0]: re.split(" {3,}", l)[1:] for l in shown[1:]}


shown, cells = table()
check(shown[0].split() == ["1", "Oct", "2", "Oct", "3", "Oct"], "the three newest nights: %s" % shown[0])
check(cells["unreviewed"] == ["20 \u21935", "14 \u21936", "7 \u21937"]
      and cells["Doctors 7d"] == ["30.0 %", "26.5 %", "22.9 %"] and cells["Speed"] == ["5", "4", "3"]
      and cells["P1+P2"] == ["9", "8", "6"],
      "goal rows, the oldest column's debt against the night before it:\n" + "\n".join(shown))
check(re.search(r"^to plateau +4$", "\n".join(shown), re.M)
      and len({len(l) for l in shown}) == 1, "one plateau value, in this night's column:\n" + "\n".join(shown))
check(cells["Opus spend"] == ["96 %", "\u2013", "85 %"] and cells["vs all-Opus"] == ["\u00d70.96", "\u2013", "\u00d70.39"]
      and "Fable spend" not in cells, "the model mix of each night, no Fable row without Fable spend: %s" % cells)
unreviewed = lambda debt, was: dict(T.table_column("/usr/bin/false", os.path.join(goal_dir, "n3.json"), running,
                                                   {"backlog": {"debt": debt}}, {"backlog": {"debt": was}}))["unreviewed"]
check([unreviewed(2300, 1100), unreviewed(7, 7), unreviewed(40, 0), unreviewed(7, None), unreviewed(None, 7)]
      == ["2.3k ↑1.2k", "7 =", "40 ↑40", "7", "–"],
      "unreviewed lines grow, plateau or shrink against the night before in lines; a night with no stored count is a "
      "dash and the night after it shows its count alone")
check(not hasattr(night_spend, "goal_lines"), "the goals live in the table only, never in a second block")
mixes["n2"] = {"opus": 40.0, "fable": 55.0, "vs_opus": 1.4}
check(table()[1]["Fable spend"] == ["\u2013", "55 %", "\u2013"], "a Fable row once any shown night spent on Fable")
os.environ["CODE_DOCTOR_DIR"] = os.path.join(work, "goal-none")
check(table()[1]["to plateau"] == ["\u2013"] and table()[1]["P1+P2"][-1] == "\u2013",
      "an unreadable doctor leaves the P1+P2 backlog unknown and no plateau")
os.environ["CODE_DOCTOR_DIR"] = os.path.join(work, "goal-code")
json.dump({"problem_count": 30, "problems": [{"id": "l%d" % i, "rule": "leg-failure", "state": "new"} for i in range(30)]},
          open(os.path.join(work, "goal-llm", "latest.json"), "w"))
check(table()[1]["to plateau"] == ["\u2013"], "a growing P1+P2 backlog leaves no plateau")
T.cached_row = kept_row
# The model mix comes from the spend itself: each label's share of the Opus-eq total, and the total over what the
# same tokens cost on Opus at token-map's prices.
bench = os.path.join(work, "stats", "benches", "20261005T030000Z-mix")
os.makedirs(bench)
json.dump({"session": "mix-s"}, open(os.path.join(bench, "meta.json"), "w"))
lines(os.path.join(bench, "claude-usage-a.jsonl"), [
    {"id": "o", "model": "claude-opus-5-5", "input": 1000000},
    {"id": "s", "model": "claude-sonnet-5-5", "input": 1000000}])
mix_night = {"id": "m", "started_at": "2026-10-05T02:00:00Z", "finished_at": "2026-10-05T08:00:00Z", "session": "mix-s"}
spent = night_spend.spend(mix_night, "/usr/bin/false")
check(abs(spent["all_opus"] - 2.0e6) < 1 and night_spend.mix(spent) == {"opus": 66.7, "vs_opus": 0.75},
      "1M Opus-eq on Opus, 0.5M on Sonnet of 2M Opus tokens' worth: %s %s" % (spent.get("all_opus"), night_spend.mix(spent)))
lines(os.path.join(bench, "claude-usage-a.jsonl"), [{"id": "f", "model": "claude-fable-5-1", "input": 400000}])
check(night_spend.mix(night_spend.spend(mix_night, "/usr/bin/false")) == {"opus": 40.0, "fable": 40.0, "vs_opus": 1.042},
      "Fable counts on its own: %s" % night_spend.mix(night_spend.spend(mix_night, "/usr/bin/false")))
check(night_spend.all_opus is None and night_spend.weighted(night_spend.bench_usage(bench)) > 0
      and night_spend.all_opus is None, "outside spend() nothing accumulates the Opus basis")
finished = dict(running, finished_at="2026-10-03T08:00:00Z", doctors_after={n: 1 for n in ("llm", "harness", "updater", "code", "system")})
check(night_spend.night_goals(finished) == {"doctors_share": None, "backlog": {}},
      "a finished night without stored goals keeps no backlog row, never today's values")

# needs Egor counts every open trade addressed to him once, from every store that holds one: an unanswered
# blocked-on-egor job, a handoff whose Status reads trade, audit rows with verdict trade, a doctor row that needs his
# word; rows naming one handoff are one trade, and a row whose handoff is settled is answered.
import handoffs
os.environ["DOCTORS_DIR"] = os.path.join(work, "egor")
os.environ["SPEND_LEDGER"] = os.path.join(work, "egor-spend-ledger.json")
os.environ["HARNESS_LEDGER"] = os.path.join(work, "egor-harness-ledger.json")
egor_nights = os.path.join(work, "egor", "nights")
os.makedirs(egor_nights)
os.makedirs(os.path.join(work, "repo", "docs", "handoffs"))
for name, status in (("hook", "open"), ("done", "settled 2026-10-02: cut"), ("ask", "trade for Egor")):
    with open(os.path.join(work, "repo", "docs", "handoffs", "2026-10-01-%s.md" % name), "w") as handle:
        handle.write("# x\n\nStatus: %s\n" % status)
json.dump({"rows": [
    {"id": "cpu:a", "verdict": "trade", "note": "handoff docs/handoffs/2026-10-01-hook.md: settings, Egor's step"},
    {"id": "cpu:b", "verdict": "trade", "note": "same filter, docs/handoffs/2026-10-01-hook.md"},
    {"id": "suite:r/test_lone", "title": "r/test_lone", "verdict": "trade", "note": "a coverage trade"},
    {"id": "cpu:c", "verdict": "trade", "note": "answered in docs/handoffs/2026-10-01-done.md"},
    {"id": "cpu:d", "verdict": "cut"}, {"id": "suite:r/test_k", "verdict": "kept"}]},
    open(os.environ["SPEND_LEDGER"], "w"))
os.environ["CODE_DOCTOR_DIR"] = os.path.join(work, "egor-code")
os.makedirs(os.environ["CODE_DOCTOR_DIR"])
json.dump({"problem_count": 1, "problems": [{"id": "reg:x", "state": "new", "needs_egor": True,
                                             "trade": "see docs/handoffs/2026-10-01-ask.md"}]},
          open(os.path.join(os.environ["CODE_DOCTOR_DIR"], "latest.json"), "w"))
egor = {"id": "e1", "started_at": "2026-10-04T02:00:00Z", "finished_at": "2026-10-04T08:00:00Z",
        "backlog": {"debt": 1}, "jobs": [
            {"kind": "trade", "ref": "trade-q", "state": "blocked-on-egor", "reason": "keep the floor: cost 2 min"},
            {"kind": "fixer", "ref": "harness-q", "state": "blocked-on-egor", "reason": "x",
             "answer": {"words": "do it", "at": "2026-10-04T09:00:00Z"}}]}
json.dump(egor, open(os.path.join(egor_nights, "e1.json"), "w"))
trades = handoffs.egor_trades()
check([t["key"] for t in trades] == ["audit:suite:r/test_lone", "handoff:2026-10-01-ask.md", "handoff:2026-10-01-hook.md",
                                     "night:e1:trade-q"], "one trade per handoff, answered and settled ones out: %s" % trades)
T.cached_row = lambda worker_run, path: {}
egor_cells = {re.split(" {3,}", l)[0]: re.split(" {3,}", l)[1:]
              for l in T.table_lines("/usr/bin/false", os.path.join(egor_nights, "e1.json"))[1:]}
check(egor_cells["needs Egor"] == ["4"], "needs Egor is every open trade, not the night's blocked jobs: %s" % egor_cells)
egor["backlog"]["trades"] = 1
json.dump(egor, open(os.path.join(egor_nights, "e1.json"), "w"))
check(dict(T.table_column("/usr/bin/false", os.path.join(egor_nights, "e1.json"), egor,
                          night_spend.night_goals(egor, True), {}))["needs Egor"] == "1",
      "a night that stored its trades at the close keeps that count")
T.cached_row = kept_row

# The per-direction block: open P1/P2 the night closed on, its jobs landed or ruled out, the share of its fixer
# spend (each run by the night worktree it ran in) and the nights to plateau at the closed-per-night rate.
os.environ["WORKER_RUN_DIR"] = night_spend.RUNS = os.path.join(work, "dir-runs")
for run, ref in (("codex-%d-1-aaaa" % (D0 + 100), "harness-a"), ("codex-%d-2-bbbb" % (D0 + 200), "speed-b")):
    os.makedirs(os.path.join(night_spend.RUNS, run))
    shutil.copy(rollout, os.path.join(night_spend.RUNS, run, "rollout.jsonl"))
    for file, body in (("launcher", "dir-s\n"), ("session-file", os.path.join(night_spend.RUNS, run, "rollout.jsonl") + "\n"),
                       ("meta.json", json.dumps({"vendor": "codex", "workdir": "/r/.claude/worktrees/night-d2-" + ref}))):
        with open(os.path.join(night_spend.RUNS, run, file), "w") as handle:
            handle.write(body)
way_night = {"id": "d2", "started_at": iso(D0), "finished_at": iso(D0 + 3600), "session": "dir-s",
             "backlog": {"open": {"tests": [2, 1], "speed": [0, 3]}}, "jobs": [
                 {"kind": "fixer", "ref": "harness-a", "direction": "tests", "priority": "P1", "state": "merged"},
                 {"kind": "fixer", "ref": "harness-c", "direction": "tests", "priority": "P3", "state": "nothing-to-do"},
                 {"kind": "fixer", "ref": "harness-d", "direction": "tests", "priority": "P3", "state": "left"},
                 {"kind": "fixer", "ref": "speed-b", "direction": "speed", "priority": "P2", "state": "left"},
                 {"kind": "vendor", "ref": "ev-1", "state": "merged"}]}
spent = night_spend.spend(way_night, "/usr/bin/false")
check(sorted(spent["refs"]) == ["harness-a", "speed-b"] and spent["refs"]["harness-a"] > 0,
      "fixer spend by the night worktree each run worked in: %s" % dict(spent["refs"]))
ways = T.directions(way_night, os.path.join(egor_nights, "d2.json"), spent)
check(ways["tests"] == {"p1": 2, "p2": 1, "closed": 2, "spend": 50.0} and ways["updater"]["closed"] == 1
      and ways["speed"] == {"p1": 0, "p2": 3, "closed": 0, "spend": 50.0} and ways["logs"]["p1"] == 0,
      "open P1/P2 from the close, closed = landed or nothing to do, a vendor job by its kind: %s" % ways)
rows = lambda *d: [{"directions": {"tests": dict(zip(("p1", "p2", "closed"), x))}} for x in d]
check([T.plateau_nights("tests", rows(*d)) for d in (
    [(5, 4, 1), (4, 3, 3)], [(3, 3, 1), (4, 3, 1)], [(None, None, 2), (0, 0, 2)], [(2, 2, 0)], [(None, None, 1)])]
      == ["4", "–", "0", "–", "–"],
      "nights to plateau: open over closed a night; a dash when it grew, nothing closes or nothing is known")
T.cached_row = lambda worker_run, path: {"directions": ways} if path.endswith("d2.json") else None
json.dump(way_night, open(os.path.join(egor_nights, "d2.json"), "w"))
block = T.direction_lines("/usr/bin/false", os.path.join(egor_nights, "d2.json"))
check(block[0].split() == ["P1", "P2", "P3", "fixers", "to", "plateau"]
      and [l.split()[0] for l in block[1:]] == ["speed", "tests", "updater"]
      and block[1].split() == ["speed", "0/1", "50", "%", "–"] and block[1].index("0/1") + 1 == block[0].index("P2")
      and block[2].index("1/2") + 1 == block[0].index("P3")
      and block[2].split() == ["tests", "✓", "1/1", "1/2", "50", "%", "2"]
      and block[3].split() == ["updater", "✓", "1/1", "0", "%", "0"] and len({len(l) for l in block}) == 1,
      "a row per direction with jobs: done/total of its P1, P2, P3 jobs (a vendor job by its kind), ✓ once all are "
      "done, blank for none, aligned:\n" + "\n".join(block))
T.cached_row = kept_row

# The improvement pool: the audit and harness ledgers and Speed's due selections and proofs, a row per class.
json.dump({"rows": [{"id": "a", "status": "open"}, {"id": "b", "status": "fixed"}, {"id": "c", "status": "fixed-pending"},
                    {"id": "log_audit:x", "status": "ruled-out"},
                    {"id": "d", "status": "open", "handoff": "docs/handoffs/2026-10-01-hook.md"}]},
          open(os.environ["HARNESS_LEDGER"], "w"))
os.makedirs(os.path.join(work, "pool-harness"))
os.environ["HARNESS_DOCTOR_DIR"] = os.path.join(work, "pool-harness")
json.dump({"speed": {"suites": {"selection": ["s1", "s2"], "proofs": {"r/test_k": {"proven": True}}},
                     "cpu": {"selection": [], "proofs": {"d": {"before": 9.0, "after": 3.0}}}}},
          open(os.path.join(work, "pool-harness", "latest.json"), "w"))
pool = {l.split()[0]: l.split()[1:] for l in T.pool_lines()[1:]}
check(T.pool_lines()[0].split() == ["open", "done", "proven", "kept", "trade"]
      and pool == {"suite": ["2", "0", "1", "1", "1"], "cpu": ["0", "1", "1", "0", "3"], "harness": ["1", "2", "1", "0", "1"],
                   "logs": ["0", "0", "0", "1", "0"], "total": ["3", "3", "3", "2", "5"]},
      "a row per class, totals last: %s" % pool)

# A fixed-pending row the doctor's overlay settles counts as fixed (proven), the merged view every ledger reader takes.
settling = {"at": "2026-10-01T00:00:00Z", "in": "llm-legs@abc"}
json.dump({"rows": json.load(open(os.environ["HARNESS_LEDGER"]))["rows"] + [{"id": "e", "status": "fixed-pending", "fixes": [settling]}]},
          open(os.environ["HARNESS_LEDGER"], "w"))
json.dump({"rows": {"e": {settling["at"]: {"in": settling["in"], "status": "fixed"}}}},
          open(os.path.join(work, "pool-harness", T.fix_commit.SETTLED_FILE), "w"))
settled_pool = {l.split()[0]: l.split()[1:] for l in T.pool_lines()[1:]}
check(settled_pool["harness"] == ["1", "3", "2", "0", "1"],
      "an overlay-settled fixed-pending row counts proven: %s" % settled_pool["harness"])

kept_journal = os.path.join(work, "kept", "runs.jsonl")
lines(kept_journal, [{"ended_at": 1, "queued_at": 0}])
opened = []
sys.addaudithook(lambda event, args: event == "open" and args[0] == kept_journal and args[1] == "r" and opened.append(1))
first = [list(night_spend.rows(kept_journal, keep=True)) for _ in range(3)]
lines(kept_journal, [{"ended_at": 2, "queued_at": 1}])
grown = list(night_spend.rows(kept_journal, keep=True))
check(len(opened) == 2 and first == [[{"ended_at": 1, "queued_at": 0}]] * 3 and len(grown) == 2,
      "a kept journal is read once per content and again once it grows: %d opens, %s" % (len(opened), grown))
print(count[0])
EOF
) || exit 1
printf 'PASS: test_time_budget.sh (%s asserts)\n' "$asserts"
