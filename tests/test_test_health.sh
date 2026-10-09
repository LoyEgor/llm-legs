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
write("docs/shared-invariants.md", "| a row | bin/tool-y |\n")
write("tests/helper.sh", "run tool-x\n")
write("tests/test_a.sh", 'run "$ROOT/bin/tool-a"\n')
write("tests/test_b.sh", '. helper.sh\n[ -x "$ROOT/bin/gone-tool" ]\n')
write("tests/test_c.sh", "tool-a.sh is no tool; tool-a is\n")
write("tests/test_never.sh", "ok\n")
write("tests/test_consistency.sh", "invariants\n")
write("tests/test_slow.sh", "sleep\n")
write("tests/test_busy.sh", "work\n")
write("tests/e2e_surfaces.sh", "tool-a live\n")
git("add", "-A")
git("commit", "-qm", "suites", at=NOW - 20 * 86400)
for i, at in enumerate((NOW - 3 * 86400, NOW - 2 * 86400, NOW - 3600)):
    write("bin/tool-a", "a%d\n" % i)
    git("commit", "-qam", "tool-a %d" % i, at=at)
write("bin/tool-x", "x1\n")
git("commit", "-qam", "tool-x", at=NOW - 7200)

rows = []


def row(start, end, suites, queued=None, who=None, checkout=repo, tree=None, head=None, scope="named", kind="suites",
        signal=None):
    rows.append({"kind": kind, "queued_at": queued or start, "started_at": start, "ended_at": end, "repo": checkout,
                 "repo_root": repo, "head": head, "tree": tree, "scope": scope, "signal": signal,
                 "complete": signal is None, "worker_run": who if who and who.startswith("w") else None,
                 "session": who if who and who.startswith("s") else None,
                 "suites": {n: {"rc": rc, "secs": secs, "cpu_s": cpu} for n, rc, secs, cpu in suites}})


T = NOW
row(T - 3000, T - 1800, [("test_a.sh", 0, 600, 300), ("test_c.sh", 0, 600, 300)], queued=T - 3300, who="s-chat")
row(T - 2000, T - 1500, [("test_a.sh", 0, 500, 250)], who="s-chat")
row(T - 9000, T - 8000, [("test_a.sh", 0, 1000, 500)], who="w-one", checkout=wt, tree="t1")
row(T - 7000, T - 6900, [("test_a.sh", 0, 100, 50)], who="w-one", checkout=wt, tree="t1")
row(T - 6800, T - 6700, [("test_a.sh", 0, 100, 50)], who="w-one", checkout=wt, tree="t2")
row(T - 6800, T - 6700, [("test_a.sh", 0, 100, 50)], who="w-two", checkout=repo, tree="t1")
row(T - 7500, T - 7400, [("test_c.sh", 0, 100, 50)], who="s-orch", checkout=wt)
row(T - 6000, T - 5800, [("test_c.sh", 0, 200, 100)], who="s-orch", checkout=wt)
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
    row(T - 86400 * 5 + i * 600, T - 86400 * 5 + i * 600 + 100, [("test_slow.sh", 0, 100 + i, 10),
                                                                ("test_busy.sh", 0, 100 + i, 95)], scope="direct",
        kind="direct")
for back in (2, 3, 4):
    row(T - back * 86400, T - back * 86400 + 600, [("test_a.sh", 0, 600, 300)], who="s-old", queued=T - back * 86400)
old = dict(rows[0], ended_at=T - 31 * 86400, queued_at=T - 31 * 86400 - 10, started_at=T - 31 * 86400 - 5)
with open(journal, "w") as handle:
    handle.write("".join(json.dumps(r) + "\n" for r in rows))
    handle.write("not json\n")

section = th.collect(NOW, journal, [repo], write=True)
now = section["now"]
check(abs(now["wait_chat"] - (1800 + 4 * 50 + 40 + 100 + 200) / 60.0) < 0.01,
      "wait: a chat's overlapping suite runs count once, queued to end, every chat summed: %s" % now["wait_chat"])
check(abs(now["wait_worker"] - (1000 + 100 + 100 + 100) / 60.0) < 0.01, "wait: workers apart, per run: %s" % now["wait_worker"])
check(now["repeats"] == 1, "retests: only a rerun of a tree already green on the same checkout is a repeat, a new tree "
      "or another checkout is not: %s" % now["repeats"])
check(now["posts"] == 1 and abs(now["post_h"] - 200 / 3600.0) < 1e-6,
      "retests: a chat's run in a worktree after its worker's last run counts, one before it does not")
check(abs(now["retests"] - 300 / 60.0) < 0.01, "retests: their wall in min/day: %s" % now["retests"])
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
check(abs(now["queue"] - 100.0 * 300 / (1500 + 500 + 1000 + 100 * 3 + 100 + 200 + 50 * 8 + 40)) < 1e-6,
      "slot queue: start minus queued over queued to end of run-suites rows: %s" % now["queue"])
check(section["usual"]["wait_chat"] == 10.0 and section["usual_days"] == 4,
      "usual: the median over the days before today that ran any suite: %s" % section["usual"])

findings = {f["target"]: f for f in section["findings"]}
idle = findings.get("test-health/idle/alpha/test_slow")
check(idle and abs(idle["min_day"] - (101 - 10) * 10 / 60.0 / 7) < 0.01 and "test-health/idle/alpha/test_busy" not in findings,
      "idle: p10 wall far over the CPU of the fastest runs is idle, a busy suite is not: %s" % idle)
check(findings["test-health/flaky/alpha/test_b"]["exposure"] == 2, "flaky: one finding per suite, its flakes counted")
check(findings["test-health/retests"]["exposure"] == 2, "retests: one finding over both kinds")
files = {f["path"]: f for f in section["fan_out"]}
check(files["bin/tool-a"]["suites"] == 2 and files["bin/tool-a"]["changes"] == 3,
      "fan-out: tool-a pulls the two suites naming it as a word, never the live e2e suite: %s" % files.get("bin/tool-a"))
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

dead = section["candidates"]
check(set(dead) == {"alpha/test_b"} and "bin/gone-tool" in dead["alpha/test_b"]["reason"],
      "dead: a suite naming a $ROOT path the repo lost; never-run is unjudged while the journal covers < 30 days: %s"
      % sorted(dead))
with open(journal) as handle:
    kept = handle.read()
with open(journal, "w") as handle:
    handle.write(json.dumps(old) + "\n" + kept)
dead = th.collect(NOW, journal, [repo])["candidates"]
check(dead.get("alpha/test_never", {}).get("reason") == "no run in 30 days" and "alpha/test_a" not in dead,
      "dead: once the journal covers 30 days, a suite no runner ran is a candidate: %s" % sorted(dead))

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
check(heavy and heavy[0][3].split()[-3] == "test_a" and len(heavy) <= th.TOP, "block: heaviest suites by wall first")

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

ledger = os.environ["SPEND_LEDGER"]
audits = suite_audit.collect(NOW, journal, work, section["candidates"])
due = {p["suite"]["component"]: p["suite"]["due"] for p in audits["problems"]}
check(due.get("alpha/test_b", "").startswith("dead: names $ROOT/bin/gone-tool"),
      "suite audits: a dead suite is queued with its reason: %s" % due.get("alpha/test_b"))
print(count[0])
EOF
) || exit 1
echo "PASS: $asserts asserts"
