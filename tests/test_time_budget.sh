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
  INSTRUCTION_WATCH_STATE="$WORK/watch" NIGHT_RUN_SWEEP_REPOS="$WORK/sweep-repos" \
  GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
unset HARNESS_WAITS_DIR XDG_CACHE_HOME RUN_SUITES_TIMES CLAUDEB_DIR
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
import json, os, subprocess, sys

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
      [{"class": "lock", "source": "x", "started": D0 + 7100, "seconds": 40, "pid": 1},
       {"class": "night-workers", "source": "j", "started": D0 + 1000, "seconds": 600, "pid": 1}])
lines(os.path.join(work, "watch", "gates.jsonl"), [{"at": D0 + 100, "decision": "denied"},
                                                   {"at": D0 + 100, "decision": "passed"}])

split = T.run_split(run, 0, 1e12, T.suite_rows(0, 1e12), T.event_rows(D0, D0 + 86400)["c"],
                    T.event_rows(D0, D0 + 86400)["h"])
check(dict((k, round(v)) for k, v in split.items() if v) == {
    "slot": 600, "retries": 400, "suite_wait": 1000, "suite_run": 2000, "tools": 500, "hooks": 100, "model": 4400}
      and round(sum(split.values())) == 9000,
      "a worker run's wall starts at its pid, not the restamped started_at: slot queue, retries, its own suites "
      "(the call inside them absorbed), tools net of their hooks, the rest model: %s" % dict(split))
clipped = T.run_split(run, D0 + 5000, D0 + 7300, T.suite_rows(0, 1e12), [], [])
orphan = T.run_split(dict(run, run="claudeb-1-9-none"), 0, 1e12, [], [], [])
check(round(clipped["suite_run"]) == 1000 and round(clipped["model"]) == 1300 and round(sum(clipped.values())) == 2300
      and round(orphan["other"]) == 8000 and not orphan["model"],
      "a window clips every span, and a run with no session file is unsplit, never model: %s %s"
      % (dict(clipped), dict(orphan)))

NOW = D0 + 20 * 3600
for back in range(1, 8):
    day = T.local_day(D0 - back * 86400)
    T.write_json(T.day_cache_path(day), {"settled": True, "seconds": {"suite_wait": 100, "suite_run": 1100, "model": 5000},
                                         "worker": {}})
doc = T.document(NOW)
by = {r["class"]: r for r in doc["classes"]}
check(by["model"]["min"] == 80.0 and by["tools"]["min"] == round(760 / 60.0, 1) and by["locks"]["min"] == round(40 / 60.0, 1)
      and by["review"]["min"] == 10.0 and by["suite_run"]["min"] == round(2080 / 60.0, 1)
      and by["other"]["min"] == round(50 / 60.0, 1) and doc["refusals"] == 1 and doc["worker_runs"] == 2,
      "the classes add owner turns (dark time out) to worker runs, lock and poll waits come out of tool time, a review "
      "round is its own class, gate refusals are counted: %s" % {k: v["min"] for k, v in by.items()})
check(doc["total_min"] == round(10550 / 60.0, 1) and doc["harness_share"] == round(4940 / 10550.0, 3)
      and doc["lines"][0] == "Without the harness ≈ 47 % faster: 82 min of 2.9 h in 24 h"
      and abs(sum(r["share"] for r in doc["classes"]) - 1) < 0.01,
      "the headline is the harness classes over the total, the shares sum to one: %s" % doc["lines"][0])
check(doc["band_days"] == 7 and by["suite_wait"]["usual_min"] == round(100 / 60.0, 1)
      and doc["holes"] == ["suite slot wait: 17 min, usually 2 min"]
      and "Hole: suite slot wait: 17 min, usually 2 min" in doc["lines"],
      "a harness class past twice its 7-day median by 15 minutes is a named hole; one under twice its median, one "
      "under the floor or a plain class never is: %s" % doc["holes"])
check(T.holes({"worker": {"model": 900, "suite_run": 4500, "slot": 4600}, "seconds": {}}, {})
      == ["workers worked 9 % of their time; 45 % went to their own tests, 46 % to the slot queue"]
      and T.holes({"worker": {"model": 4000, "suite_run": 6000}, "seconds": {}}, {}) == [],
      "workers under 30 % model time are a named hole, at 40 % they are not")
t = doc["tests"]
check(t["runs"] == 2 and t["wait_h"] == round(1000 / 3600.0, 2) and t["run_h"] == round(2100 / 3600.0, 2)
      and t["by_caller_h"] == {"workers": round(3000 / 3600.0, 2), "chats": round(100 / 3600.0, 2)}
      and [s["suite"] for s in t["slowest"]] == ["test_b.sh", "test_a.sh"] and t["slowest"][1]["median_s"] == 75
      and "Tests: 0.9 h in 2 suite runs, 32 % waiting for a slot" in doc["lines"],
      "test time: hours by caller, slot wait against running, the slowest suites by median: %s" % t)
lever = {x["lever"]: x for x in doc["levers"]}
check(lever["prompt-cache hits"]["value"] == "90 % of cached input read from cache"
      and lever["parallel tool calls"]["value"] == "0 % of 3 tool calls ran beside another"
      and lever["fewer process starts"]["value"] == "1 CLI starts, 0.1 min launching"
      and lever["smaller context per turn"]["measured"] is False,
      "levers are measured where the journals hold the data and marked ideas where not: %s" % lever)
gap = {f["class"]: f["recoverable_min_day"] for f in doc["floors"]}
check(gap == {"hooks": 3.3, "stop": 0.3, "suite_wait": 16.7, "slot": 10.0, "retries": 6.7, "locks": 0.7, "suite_run": 0.0}
      and doc["lost_min_day"] == 37.7 and T.recoverable("suite_run", 7200, 1) == 60.0
      and T.recoverable("model", 9999, 1) == 0.0 and T.recoverable("slot", 600, 0.5) == 20.0
      and doc["lines"][2] == "Over the floor: 38 min/day recoverable · suite slot wait 17 min · worker slot queue 10 min"
      " · retries and relaunches 7 min",
      "each class is judged against its floor: zero for hooks, gates and waits, a 60 min/day suite budget for tests, "
      "none for plain Claude Code; the gap is recoverable min/day: %s %s" % (gap, doc["lines"][2]))
active = T.worker_floor({"model": 900, "suite_run": 4500, "slot": 4600}, 1)
check(active == {"share": 0.09, "floor_share": 0.7, "recoverable_min_day": 101.7}
      and T.worker_floor({"model": 7000, "suite_run": 3000}, 1)["recoverable_min_day"] == 0.0
      and doc["workers_active"]["floor_share"] == 0.7,
      "workers are judged against 70 %% model activity of their wall, the shortfall is recoverable: %s" % active)
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
                  "trend · problems -2 over 2 nights · moving forward"],
      "the trend: one line per night oldest first, an untimed night reads ?, and the direction: %s" % out[6:10])
check(out[10:] == ["roi · harness-x-20260110T000000Z · suite slot wait · 0.0M · +5/-1 lines · saves 1.0 min/day",
                   "roi · harness-y-20260110T000000Z · suites running · 0.0M · +0/-0 lines · not landed",
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
cached = json.load(open(os.path.join(work, "doctors", "night-ledger", "N1.json")))
check(cached["wall_s"] == 9000 and cached["split_s"]["slot"] == 600,
      "a finished night's ledger row is cached, so its numbers outlive the pruned run and event stores")
with open(T.ledger_cache("N1"), "w") as handle:
    json.dump(dict(cached, wall_s=12000, split_s=dict(cached["split_s"], model=1200)), handle)
check(T.last_night() == {"id": "N1", "wall_s": 12000, "model_s": 1200, "share": 0.1},
      "the last night's worker activity is the newest finished night's cached ledger row: %s" % T.last_night())
print(count[0])
EOF
) || exit 1
printf 'PASS: test_time_budget.sh (%s asserts)\n' "$asserts"
