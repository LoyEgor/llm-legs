#!/usr/bin/env bash
. "${BASH_SOURCE%"${BASH_SOURCE##*/}"}lib/suite-journal.sh"
# share/test_health.py off a fixture repository and run-suites journal: each class (wait as a union per caller,
# exact repeats by tree, post-worker retests, runs per landed change, fan-out through tests/affected's reading with
# its cache, idle on the fastest runs, red and flaky, contention and slot queue, heavy, dead), the usual and its red
# lines, Speed's opportunities from the findings and suite_audit's queue of dead suites. Fixture directories only.
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

asserts=$(python3 - "$ROOT" "$WORK" <<'EOF'
import importlib.machinery, importlib.util, json, os, subprocess, sys, time

root, work = sys.argv[1], sys.argv[2]
count = [0]


def check(cond, what):
    count[0] += 1
    if not cond:
        print("FAIL: %s" % what, file=sys.stderr)
        sys.exit(1)


NOW = time.mktime(time.strptime(time.strftime("%Y-%m-%d") + " 12:00", "%Y-%m-%d %H:%M"))
repo = os.path.join(work, "repos", "alpha")
wt = os.path.join(repo, ".claude", "worktrees", "feat-x")
journal = os.path.join(work, "runs.jsonl")
os.environ.update({"NIGHT_RUN_SWEEP_REPOS": os.path.join(work, "sweep-repos"), "NIGHT_RUN_HELPER_REPOS": os.devnull,
                   "SPEND_LEDGER": os.path.join(work, "spend-ledger.json"), "RUN_SUITES_JOURNAL": journal,
                   "HARNESS_DOCTOR_DIR": os.path.join(work, "harness"), "HARNESS_WAITS_DIR": os.path.join(work, "waits"),
                   "DOCTORS_DIR": os.path.join(work, "doctors"),
                   "GIT_AUTHOR_NAME": "t", "GIT_AUTHOR_EMAIL": "t@t", "GIT_COMMITTER_NAME": "t",
                   "GIT_COMMITTER_EMAIL": "t@t"})
with open(os.environ["NIGHT_RUN_SWEEP_REPOS"], "w") as handle:
    handle.write(repo + "\n")
sys.path.insert(0, os.path.join(root, "share"))
import suite_audit  # noqa: E402
import test_health as th  # noqa: E402


def write(rel, text):
    os.makedirs(os.path.dirname(os.path.join(repo, rel)), exist_ok=True)
    with open(os.path.join(repo, rel), "w") as handle:
        handle.write(text)


def git(*args, at=None):
    env = dict(os.environ, **({"GIT_AUTHOR_DATE": "@%d" % at, "GIT_COMMITTER_DATE": "@%d" % at} if at else {}))
    return subprocess.run(["git", "-C", repo] + list(args), capture_output=True, text=True, env=env,
                          check=True).stdout.strip()


os.makedirs(repo)
git("init", "-q")
write("bin/tool-a", "a\n")
write("bin/tool-x", "x\n")
write("bin/tool-y", "y\n")
write("bin/tool-z", "z\n")
write("docs/shared-invariants.md", "| a row | bin/tool-y |\n| b row | bin/tool-z |\n")
write("tests/helper.sh", "run tool-x\n")
write("tests/test_a.sh", 'run "$ROOT/bin/tool-a"\n')
write("tests/test_b.sh", '. helper.sh\n[ -x "$ROOT/bin/gone-tool" ]\n')
write("tests/test_c.sh", "tool-a.sh is no tool; tool-a is\n")
write("tests/test_never.sh", "ok\n")
write("tests/test_consistency.sh", "invariants\n")
write("tests/test_slow.sh", "sleep\n")
write("tests/test_busy.sh", "work\n")
write("tests/e2e_surfaces.sh", "tool-a live\n")
write("tests/test_ondemand.sh", "slow\n")
write("tests/test_probe_live.sh", "live\n")
write("tests/slow-suites", "test_ondemand.sh\n")
write("tests/test_made.sh", 'mkdir -p "$ROOT/out/cache"\n[ ! -e "$ROOT/bin/removed" ]\necho \'$ROOT/bin/quoted\'\n'
      'python3 - <<\'PY\'\nprint("$ROOT/bin/in-heredoc")\nPY\ncat > "$ROOT/bin/written"\n')
write("docs/notes.md", "notes\n")
pin = "assert grep -qF 'line %d' \"$ROOT/docs/notes.md\"\n"
write("tests/test_pinned.sh", "".join(pin % i for i in range(4)) + "assert grep -q z \"$ROOT/bin/tool-z\"\n"
      "assert grep -q z \"$WORK/out\"\n")
git("add", "-A")
git("commit", "-qm", "suites", at=NOW - 20 * 86400)
for i, at in enumerate((NOW - 3 * 86400, NOW - 2 * 86400, NOW - 3600)):
    write("bin/tool-a", "a%d\n" % i)
    git("commit", "-qam", "tool-a %d" % i, at=at)
for i, at in enumerate((NOW - 4 * 86400, NOW - 2.5 * 86400)):
    write("tests/test_pinned.sh", "".join(pin % k for k in range(5 + i)) + "assert grep -q z \"$ROOT/bin/tool-z\"\n")
    git("commit", "-qam", "pin %d" % i, at=at)
write("bin/tool-x", "x1\n")
git("commit", "-qam", "tool-x", at=NOW - 7200)
os.makedirs(os.path.join(work, "doctors", "nights"))
iso = lambda t: time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(t))
with open(os.path.join(work, "doctors", "nights", "n1.json"), "w") as handle:
    json.dump({"id": "n1", "started_at": iso(NOW - 40000), "finished_at": iso(NOW - 30000)}, handle)

rows = []


def row(start, end, suites, queued=None, who=None, checkout=repo, tree=None, head=None, scope="named", kind="suites",
        signal=None, j=None, sleep=None):
    rows.append({"kind": kind, "queued_at": queued or start, "started_at": start, "ended_at": end, "repo": checkout,
                 "repo_root": repo, "head": head, "tree": tree, "scope": scope, "signal": signal,
                 "complete": signal is None, "worker_run": who if who and who.startswith("w") else None,
                 "session": who if who and who.startswith("s") else None, "j": j,
                 "suites": {n: dict({"rc": rc, "secs": secs, "cpu_s": cpu}, **({"sleep_s": sleep} if sleep else {}))
                            for n, rc, secs, cpu in suites}})


T = NOW
row(T - 3000, T - 1800, [("test_a.sh", 0, 600, 300), ("test_c.sh", 0, 600, 300)], queued=T - 3300, who="s-chat")
row(T - 2000, T - 1500, [("test_a.sh", 0, 500, 250)], who="s-chat")
row(T - 9000, T - 8000, [("test_a.sh", 0, 1000, 500)], who="w-one", checkout=wt, tree="t1")
row(T - 7000, T - 6900, [("test_a.sh", 0, 100, 50)], who="w-one", checkout=wt, tree="t1")
row(T - 6800, T - 6700, [("test_a.sh", 0, 100, 50)], who="w-one", checkout=wt, tree="t2")
row(T - 6800, T - 6700, [("test_a.sh", 0, 100, 50)], who="w-two", checkout=repo, tree="t1")
row(T - 7500, T - 7400, [("test_c.sh", 0, 100, 50)], who="s-orch", checkout=wt)
row(T - 6000, T - 5800, [("test_c.sh", 0, 200, 100)], who="s-orch", checkout=wt)
row(T - 6600, T - 6550, [("test_a.sh", 0, 50, 25)], who="s-orch", checkout=wt, tree="t2")
row(T - 6500, T - 6450, [("test_a.sh", 0, 50, 25)], who="s-orch", checkout=wt, tree="t6")
row(T - 39000, T - 38000, [("test_c.sh", 0, 1000, 500)], who="w-night")
row(T - 35000, T - 34000, [("test_c.sh", 0, 1000, 500)])
row(T - 20000, T - 19700, [("test_a.sh", 0, 300, 150), ("test_c.sh", 0, 20, 10), ("test_b.sh", 0, 20, 10)], j=5)
for back in (3.2, 3.1):
    row(T - back * 86400, T - back * 86400 + 10, [("test_pinned.sh", 1, 10, 5)])
row(T - 900, T - 850, [("test_b.sh", 1, 50, 25)], who="s-chat", tree="t3")
row(T - 800, T - 750, [("test_b.sh", 0, 50, 25)], who="s-chat", tree="t3")
row(T - 700, T - 650, [("test_b.sh", 1, 50, 25)], who="s-chat", tree="t4")
row(T - 600, T - 550, [("test_b.sh", 0, 50, 25)], who="s-chat", tree="t5")
row(T - 500, T - 450, [("test_b.sh", 1, 50, 25)], head="h1", scope="full")
row(T - 400, T - 350, [("test_b.sh", 0, 50, 25)], head="h1", scope="full")
row(T - 300, T - 250, [("test_b.sh", 1, 50, 25)], head="h2")
row(T - 200, T - 150, [("test_b.sh", 0, 50, 25)], head="h2")
row(T - 100, T - 60, [("test_b.sh", 143, 40, 20)], who="s-chat", signal=15)
for i in range(10):
    back = 2 + i % 4
    row(T - 86400 * back + i * 600, T - 86400 * back + i * 600 + 100, [("test_slow.sh", 0, 100 + i, 10),
                                                                ("test_busy.sh", 0, 100 + i, 95)], scope="direct",
        kind="direct", sleep=30)
for back in (2, 3, 4):
    row(T - back * 86400, T - back * 86400 + 600, [("test_a.sh", 0, 600, 300)], who="s-old", queued=T - back * 86400)
old = dict(rows[0], ended_at=T - 31 * 86400, queued_at=T - 31 * 86400 - 10, started_at=T - 31 * 86400 - 5)
with open(journal, "w") as handle:
    handle.write("".join(json.dumps(r) + "\n" for r in rows))
    handle.write("not json\n")

section = th.collect(NOW, journal, [repo], write=True)
now = section["now"]
check(abs(now["wait_chat"] - (1800 + 4 * 50 + 40 + 100 + 200 + 50 + 50) / 60.0) < 0.01,
      "wait: a chat's overlapping suite runs count once, queued to end, every chat summed: %s" % now["wait_chat"])
check(abs(now["wait_worker"] - (1000 + 100 + 100 + 100) / 60.0) < 0.01,
      "wait: workers apart, per run, a night worker not among them: %s" % now["wait_worker"])
check(abs(now["wait_night"] - 2000 / 60.0) < 0.01 and abs(now["wait_terminal"] - (4 * 50 + 300) / 60.0) < 0.01,
      "wait: a run inside a night-run window is the night's whoever ran it; no caller by day is its own line: %s %s"
      % (now["wait_night"], now["wait_terminal"]))
check(now["repeats"] == 3, "retests: a rerun of content (tree) already green is a repeat on any checkout, a new tree is "
      "not: %s" % now["repeats"])
check(now["posts"] == 1 and abs(now["post_h"] - 50 / 3600.0) < 1e-6,
      "retests: a chat's run in a worktree on the content its worker ran green counts; one without a tree, or the "
      "landing rerun of new content after it, does not: %s %s" % (now["posts"], now["post_h"]))
check(abs(now["retests"] - (100 + 100 + 50) / 60.0) < 0.01, "retests: their run wall in min/day: %s" % now["retests"])
check(now["landed"] == 2 and abs(now["per_change"] - now["runs"] / 2.0) < 1e-9,
      "runs per landed change: the window's suite runs over the commits landed in it")
check(now["targeted"] == sum(len(r["suites"]) for r in rows if r["ended_at"] >= T - 86400 and r["kind"] == "suites"
                             and r["scope"] == "named") / sum(1 for r in rows if r["ended_at"] >= T - 86400 and
                                                               r["kind"] == "suites" and r["scope"] == "named"),
      "fan-out: suites per targeted run is the mean over named and changed runs")
check(now["flaky"] == 2, "flaky: red then green on one tree, or two every-suite runs of one head; a new tree or a "
      "named run of one head is no flake: %s" % now["flaky"])
judged = [(n, s) for r in rows if T - 86400 <= r["ended_at"] < T and r["signal"] is None for n, s in r["suites"].items()]
check(abs(now["red"] - 100.0 * sum(1 for _, s in judged if s["rc"]) / len(judged)) < 1e-9,
      "red: a run stopped by a signal is neither red nor green")
timed = [s for r in rows if T - 86400 <= r["ended_at"] < T for s in r["suites"].values()]
check(abs(now["contention"] - sum(s["secs"] for s in timed) / sum(s["cpu_s"] for s in timed)) < 1e-9,
      "contention: wall per CPU second over the window's suite runs")
ended = [r for r in rows if T - 86400 <= r["ended_at"] < T and r["kind"] == "suites"]
check(abs(now["queue"] - 100.0 * 300 / sum(r["ended_at"] - r["queued_at"] for r in ended)) < 1e-6
      and sum(r["started_at"] - r["queued_at"] for r in ended) == 300,
      "slot queue: start minus queued over queued to end of run-suites rows: %s" % now["queue"])
check(section["usual"]["wait_chat"] == 10.0 and section["usual_days"] == 4,
      "usual: the median over the days before today that ran any suite: %s" % section["usual"])

findings = {f["target"]: f for f in section["findings"]}
idle = findings.get("test-health/idle/alpha/test_slow")
check(idle and abs(idle["min_day"] - min(sum(50.0 * 30 / (100 + i) for i in range(k, 10, 4)) for k in range(4))
                   / 60.0) < 0.01
      and "test-health/idle/alpha/test_busy" not in findings,
      "idle: p10 wall far over the CPU of the fastest runs is idle, bounded by the profiled sleeps, on the run's wall "
      "share, priced at the median of the 7 days' sums; a busy suite is not: %s" % idle)
check(idle["confidence"] == "measured" and "bounded by the sleeps 10 profiled runs" in idle["fact"],
      "idle: a profiled bound reads measured: %s" % idle)
check(findings["test-health/flaky/alpha/test_b"]["exposure"] == 2, "flaky: one finding per suite, its flakes counted")
check(findings["test-health/retests"]["exposure"] == 3, "retests: one finding over every repeat")
check(findings["test-health/idle/alpha/test_a"]["confidence"] == "estimated",
      "idle: without a profiled run any wait counts and reads estimated")
regs = {r["key"]: r for r in section["regressions"]}
check("wait_chat" in regs and abs(regs["wait_chat"]["min_day"] - round(now["wait_chat"] - 10.0, 1)) < 1e-9
      and set(regs) == {k for k, _, _, m in th.LINES if th.red_line(k, now[k], section["usual"][k], m)},
      "regressions: every line read red is a row with its minutes a day over the usual: %s" % regs)
files = {f["path"]: f for f in section["fan_out"]}
check(files["bin/tool-a"]["suites"] == 2 and files["bin/tool-a"]["changes"] == 3,
      "fan-out: tool-a pulls the two suites naming it as a word, never the live e2e suite: %s" % files.get("bin/tool-a"))
check(files["bin/tool-a"]["runs"] == 2 and files["bin/tool-x"]["runs"] == 7,
      "fan-out: priced from the targeted runs holding every suite a file pulls, each run to its widest file: %s"
      % section["fan_out"])
check(files["bin/tool-x"]["suites"] == 1, "fan-out: a helper a suite sources carries its names into it")
scan = th.scans([repo], {}, False)[repo]
check(th.covering(scan)["tool-y"] == {"test_consistency.sh"}, "fan-out: shared-invariants.md names pull test_consistency")
held = json.load(open(th.cache_path()))
saved, th.repo_scan = th.repo_scan, lambda top: (_ for _ in ()).throw(AssertionError("rescanned"))
check(th.scans([repo], held, False)[repo] == held[repo]["scan"], "fan-out: an unchanged repo reads its cached scan")
write("tests/test_c.sh", "now tool-x too\n")
git("commit", "-qam", "touch a suite", at=NOW - 60)
try:
    th.scans([repo], held, False)
    check(False, "fan-out: a new blob rescans")
except AssertionError:
    check(True, "fan-out: a new blob rescans")
th.repo_scan = saved
git("reset", "-q", "--hard", "HEAD~1")

pinned = section["candidates"].get("alpha/test_pinned") or {}
check(pinned.get("kind") == "pins" and pinned["reason"].startswith("6 source-text pins, its suite edited in 2 commits"),
      "pins: a suite grepping 6 source texts (an invariant file and a work file are no pins), edited twice while red, "
      "is queued for its audit: %s" % pinned)
dead = {k: v for k, v in section["candidates"].items() if v.get("kind") != "pins"}
check(set(dead) == {"alpha/test_b"} and "bin/gone-tool" in dead["alpha/test_b"]["reason"],
      "dead: a suite naming a $ROOT path the repo lost, never one it creates, removes, asserts absent or never "
      "expands; never-run is unjudged while the journal covers < 30 days: %s" % sorted(dead))
with open(journal) as handle:
    kept = handle.read()
with open(journal, "w") as handle:
    handle.write(json.dumps(old) + "\n" + kept)
dead = th.collect(NOW, journal, [repo])["candidates"]
check(dead.get("alpha/test_never", {}).get("reason") == "no run in 30 days" and "alpha/test_a" not in dead,
      "dead: once the journal covers 30 days, a suite no runner ran is a candidate: %s" % sorted(dead))
check(not {"alpha/test_ondemand", "alpha/test_probe_live", "alpha/e2e_surfaces"} & set(dead),
      "dead: a tests/slow-suites, *_live or live suite runs on demand and is never judged unrun: %s" % sorted(dead))

lines = section["menu"]
check(lines[0][0] == 0 and lines[0][3].startswith("Test health: ") and section["head"] == lines[0][3][13:],
      "block: the head line opens it")
classes = [l for l in lines if l[0] == 1 and "usual" in l[3]]
check(len(classes) == len(th.LINES) and len({l[3].index("usual") for l in classes}) == 1,
      "block: one line per class, its usual in one column: %s" % [l[3] for l in classes])
check(any(l[3].startswith("wait · chats") and l[2] for l in lines) == th.red_line(
    "wait_chat", now["wait_chat"], 10.0, 30), "block: a class over 1.5× its usual and its least delta reads red")
check(th.red_line("x", 46, 30, 15) and not th.red_line("x", 44, 30, 15) and not th.red_line("x", 60, 40, 30)
      and not th.red_line("x", 60, None, 1), "red: over the band and the least delta, never without a usual")
heavy = [l for l in lines if l[0] == 1 and l[3].rstrip().endswith("· alpha")]
ranked = [s["min_day"] for s in section["heavy"]]
check(heavy and heavy[0][3].split()[-3] == "test_c" and [l[3].split()[-3] for l in heavy] ==
      [s["label"] for s in section["heavy"]] and ranked == sorted(ranked, reverse=True) and len(heavy) <= th.TOP,
      "block: heaviest suites by min/day first, a suite first run today priced over its one day: %s"
      % [l[3] for l in heavy])

loader = importlib.machinery.SourceFileLoader("speed_doctor", os.path.join(root, "bin", "speed-doctor"))
S = importlib.util.module_from_spec(importlib.util.spec_from_loader("speed_doctor", loader))
loader.exec_module(S)
opps = S.test_opportunities(section)
ids = {o["id"] for o in opps}
check({"opportunity:test-health/retests", "opportunity:test-health/idle/alpha/test_slow",
       "opportunity:test-health/flaky/alpha/test_b"} <= ids and all(o["rule"] == "opportunity" for o in opps),
      "speed: each finding is an opportunity: %s" % sorted(ids))
retest = next(o for o in opps if o["id"] == "opportunity:test-health/retests")
check(retest["opportunity"]["files"] and retest["opportunity"]["quality"] == "equivalent",
      "speed: an opportunity names its files and stays output-equivalent")
budget = {"floors": [{"class": "suite_run", "label": "suites running", "actual_min_day": 99, "recoverable_min_day": 50,
                      "floor_min_day": "uncontended p10 wall", "worker_min_day": 0.0}]}
ranked = S.with_time(opps, budget)
check("opportunity:time/suite_run" in {o["id"] for o in ranked}
      and all("floor_gap_min_day" not in o["opportunity"] for o in ranked if o["id"].startswith(S.TEST_HEALTH_ID)),
      "speed: a floor gap is its own time row, never folded into a test-health one")
offered = sum(o["opportunity"]["recoverable_min_day"] for o in opps)
gap = next(o for o in ranked if o["id"] == "opportunity:time/suite_run")["opportunity"]["floor_gap_min_day"]
check(0 < offered < 49 and abs(gap - round(50 - offered, 2)) < 1e-9,
      "speed: the suites-running gap is net of what test-health rows recover, one minute offered once: %s %s"
      % (gap, offered))
budget["floors"][0]["recoverable_min_day"] = offered
check("opportunity:time/suite_run" not in {o["id"] for o in S.with_time(opps, budget)},
      "speed: a gap test health already covers is no time row")
problems = {p["id"]: p for p in S.test_regressions(section, {}, NOW)}
wait_row = problems.get("regression:test-health/wait_chat") or {}
check(wait_row.get("rule") == "regression" and wait_row.get("expected_min_day") == regs["wait_chat"]["min_day"]
      and wait_row.get("component") == "test-health/wait_chat",
      "speed: a test health line over its usual is a regression row priced at its excess: %s" % wait_row)
th.HEAVY_MIN_DAY = 0.0
heavy_section = th.collect(NOW, journal, [repo])
th.HEAVY_MIN_DAY = 15.0
heavy_ids = {o["id"] for o in S.test_opportunities(heavy_section)}
moved = {"id": "opportunity:tests/alpha/test_a"}
check("opportunity:test-health/heavy/alpha/test_a" in heavy_ids
      and S.without_moved_heavy([moved, {"id": "opportunity:tests/alpha/other"}], heavy_section)
      == [{"id": "opportunity:tests/alpha/other"}],
      "speed: a heavy suite is a test-health row and drops its moved tests/ row: %s" % sorted(heavy_ids))
tool_a = next(f for f in heavy_section["fan_out"] if f["path"] == "bin/tool-a")
check(tool_a["heavy_s"] > 0 and tool_a["wall_s"] == 0 and tool_a["min_day"] == 0,
      "fan-out: minutes on suites a heavy row prices stay there and are shown, never priced twice: %s" % tool_a)

spike = os.path.join(work, "spike.jsonl")
with open(spike, "w") as handle:
    for back in range(7):
        handle.write(json.dumps({"kind": "suites", "started_at": T - back * 86400 - 2000, "ended_at": T - back * 86400
                                 - 800, "repo": repo, "repo_root": repo, "scope": "named", "j": 1, "suites": {
                                     "test_a.sh": {"rc": 0, "secs": 1200, "cpu_s": 1100}}}) + "\n")
    handle.write(json.dumps({"kind": "suites", "started_at": T - 6 * 86400 + 600, "ended_at": T - 6 * 86400 + 30600,
                             "repo": repo, "repo_root": repo, "scope": "named", "j": 1,
                             "suites": {"test_c.sh": {"rc": 0, "secs": 30000, "cpu_s": 29000}}}) + "\n")
    for back in (1, 0):
        handle.write(json.dumps({"kind": "suites", "started_at": T - back * 86400 - 3000, "ended_at": T - back * 86400
                                 - 1000, "repo": repo, "repo_root": repo, "scope": "named", "j": 1, "suites": {
                                     "test_b.sh": {"rc": 0, "secs": 1000, "cpu_s": 900}}}) + "\n")
spiked = th.collect(NOW, spike, [repo])
spiked_heavy = {f["target"] for f in spiked["findings"] if f["class"] == "heavy"}
spiked_c = next(s for s in spiked["heavy"] if s["label"] == "test_c")
check("test-health/heavy/alpha/test_c" not in spiked_heavy and spiked["heavy"][0]["label"] == "test_a"
      and spiked_c["min_day"] == 0 and spiked_c["usual_min_day"] > 60,
      "heavy: one old heavy day never ranks a suite over one that costs minutes every day; its 7-day mean stays the "
      "usual: %s %s" % (sorted(spiked_heavy), spiked["heavy"]))
check(spiked_heavy == {"test-health/heavy/alpha/test_a", "test-health/heavy/alpha/test_b"}
      and spiked["heavy"][1]["label"] == "test_b" and abs(spiked["heavy"][1]["min_day"] - 1000 / 60.0) < 0.1,
      "heavy: a suite first run 2 days ago, heavy both days, is priced over its own days and ranks heavy: %s %s"
      % (sorted(spiked_heavy), spiked["heavy"]))

mini, M = os.path.join(work, "mini.jsonl"), NOW - 3600


def mini_row(start, end, suites, tree, j, queued=None):
    return {"kind": "suites", "queued_at": queued or start, "started_at": start, "ended_at": end, "repo": repo,
            "repo_root": repo, "tree": tree, "scope": "named", "j": j, "worker_run": "w-m",
            "suites": {n: {"rc": rc, "secs": secs, "cpu_s": secs / 2.0} for n, rc, secs in suites}}


with open(mini, "w") as handle:
    for r in (mini_row(M, M + 300, [("test_a.sh", 0, 300), ("test_b.sh", 0, 20), ("test_c.sh", 0, 20)], "m1", 5, M - 10),
              mini_row(M + 400, M + 520, [("test_a.sh", 0, 100), ("test_b.sh", 0, 100), ("test_c.sh", 0, 100)],
                       "m1", 5),
              mini_row(M + 600, M + 800, [("test_a.sh", 0, 100), ("test_c.sh", 0, 100)], "m2", 1),
              mini_row(M + 900, M + 950, [("test_b.sh", 1, 50)], "m3", 5),
              mini_row(M + 1000, M + 1050, [("test_b.sh", 0, 50)], "m3", 5)):
        handle.write(json.dumps(r) + "\n")
mrows, mexecs = th.load(mini, 0)
th.label(mexecs)
th.allocate(mrows, {}, 5)
total = lambda r: sum(v for e in r["execs"] for v in e["cost"].values())
pole = mrows[0]["execs"][0]["cost"].get("pole", 0)
check(abs(total(mrows[0]) - 310) < 1e-9 and abs(pole - (300 - 340 / 3.0)) < 1e-9,
      "parallel: a run's wall, queued to end, splits whole; the long pole takes the slots idle while it runs: %s %s"
      % (total(mrows[0]), pole))
check(abs(th.cost(mrows[1]["execs"], "retests") - 120) < 1e-9,
      "retests: a rerun of concurrent suites costs its wall, never the sum of its suite seconds: %s"
      % th.cost(mrows[1]["execs"], "retests"))
check(abs(mrows[2]["execs"][0]["cost"].get("serial", 0) - 100) < 1e-9 and abs(total(mrows[2]) - 200) < 1e-9,
      "parallel: a multi-suite run on one slot loses what the usual slots would save: %s" % mrows[2]["execs"][0]["cost"])
check(mrows[3]["execs"][0]["cost"] == {"flaky": 50} and all(len(e["cost"]) == 1 for r in mrows[1:2] + mrows[3:4]
                                                              for e in r["execs"]),
      "flaky and retests: a minute in one class only: %s" % [e["cost"] for r in mrows for e in r["execs"]])

ledger = os.environ["SPEND_LEDGER"]
audits = suite_audit.collect(NOW, journal, work, section["candidates"])
due = {p["suite"]["component"]: p["suite"]["due"] for p in audits["problems"]}
check(due.get("alpha/test_b", "").startswith("dead: names $ROOT/bin/gone-tool"),
      "suite audits: a dead suite is queued with its reason: %s" % due.get("alpha/test_b"))
check(due.get("alpha/test_pinned", "").startswith("pins: 6 source-text pins"),
      "suite audits: a pinned suite is queued under its own kind: %s" % due.get("alpha/test_pinned"))
print(count[0])
EOF
) || exit 1
echo "PASS: $asserts asserts"
