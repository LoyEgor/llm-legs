#!/usr/bin/env bash
. "${BASH_SOURCE%"${BASH_SOURCE##*/}"}lib/suite-journal.sh"
# share/suite_audit.py, the Suite audits block of the Harness doctor, and time_budget's per-unit proof, off a fixture
# repository and run-suites journal: pricing over every runner, the due rules (never, a source
# blob a Speed landing did not move, 2x wall a run, a rise between commits beyond the machine's load naming its
# commit, a new heavy suite, a split that is not new, a 1 wall-min/day floor), the
# night's queue, a kept audit closing it with its proof, the restate a night close reads, the Harness menu block and
# a night improvement proven per unit (suite wall a run, hook ms a call, gate recovery s a day; test health by its suite or file) once N samples follow it. Fixture directories
# only.
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

asserts=$(python3 - "$ROOT" "$WORK" <<'EOF'
import datetime, importlib.machinery, importlib.util, json, os, subprocess, sys, time

root, work = sys.argv[1], sys.argv[2]
count = [0]


def check(cond, what):
    count[0] += 1
    if not cond:
        print("FAIL: %s" % what, file=sys.stderr)
        sys.exit(1)


NOW = time.time()
repo = os.path.join(work, "repos", "alpha")
os.makedirs(os.path.join(repo, "tests", "lib"))
for name in ("CLAUDEB_DIR", "CHAT_NAME_ROOTS", "XDG_CACHE_HOME", "RUN_SUITES_TIMES"):
    os.environ.pop(name, None)
os.makedirs(os.path.join(work, "home"))
os.environ.update({"HOME": os.path.join(work, "home"), "WORKER_STATS_DIR": os.path.join(work, "stats"),
                   "WORKER_RUN_DIR": os.path.join(work, "runs"), "INSTRUCTION_WATCH_STATE": os.path.join(work, "watch"),
                   "DOCTORS_DIR": os.path.join(work, "doctors")})
os.environ.update({"NIGHT_RUN_SWEEP_REPOS": os.path.join(work, "sweep-repos"), "NIGHT_RUN_HELPER_REPOS": os.devnull,
                   "SPEND_LEDGER": os.path.join(work, "spend-ledger.json"),
                   "RUN_SUITES_JOURNAL": os.path.join(work, "runs.jsonl"),
                   "HARNESS_DOCTOR_DIR": os.path.join(work, "harness"), "HARNESS_WAITS_DIR": os.path.join(work, "waits"),
                   "GIT_AUTHOR_NAME": "t", "GIT_AUTHOR_EMAIL": "t@t", "GIT_COMMITTER_NAME": "t",
                   "GIT_COMMITTER_EMAIL": "t@t"})
with open(os.environ["NIGHT_RUN_SWEEP_REPOS"], "w") as handle:
    handle.write(repo + "\n")


def write(rel, text):
    with open(os.path.join(repo, rel), "w") as handle:
        handle.write(text)


def git(*args, at=None):
    env = dict(os.environ, **({"GIT_AUTHOR_DATE": "@%d" % at, "GIT_COMMITTER_DATE": "@%d" % at} if at else {}))
    return subprocess.run(["git", "-C", repo] + list(args), capture_output=True, text=True, env=env,
                          check=True).stdout.strip()


git("init", "-q")
write("tests/helper.sh", "helper\n")
write("tests/lib/common.sh", "common\n")
write("tests/unused.sh", "unused\n")
write("tests/test_heavy.sh", "check 1\n")
write("tests/test_mid.sh", ". helper.sh\n. lib/common.sh\n" + "".join("case %d\n" % i for i in range(20)))
for name in ("test_light", "test_a", "test_b", "test_c", "test_d"):
    write("tests/%s.sh" % name, "ok\n")
git("add", "-A")
git("commit", "-qm", "suites", at=NOW - 10 * 86400)
cheap = git("rev-parse", "HEAD")
write("tests/test_heavy.sh", "check 1\nsleep 60\n")
git("commit", "-qam", "heavy waits a minute", at=NOW - 3 * 86400)
dear = git("rev-parse", "HEAD")
write("tests/test_new.sh", "slow\n" * 10)
git("add", "-A")
git("commit", "-qm", "a new slow suite", at=NOW - 2 * 86400)
new = git("rev-parse", "HEAD")
write("tests/test_part.sh", "".join("case %d\n" % i for i in range(10)))
write("tests/test_mid.sh", ". helper.sh\n. lib/common.sh\n" + "".join("case %d\n" % i for i in range(10, 20)))
git("add", "-A")
git("commit", "-qm", "split test_mid", at=NOW - 86400)
split = git("rev-parse", "HEAD")


def row(end, suites, head, worker=False, **extra):
    return dict({"kind": "direct", "started_at": end - 5, "ended_at": end, "repo": repo, "repo_root": repo, "head": head,
                 "worker_run": "run-1" if worker else None, "suites": {k + ".sh": v for k, v in suites.items()}},
                **extra)


def cpu(value, rc=0, **extra):
    return dict({"rc": rc, "secs": value, "cpu_s": value}, **extra)


journal = [row(NOW - 6 * 86400 + i * 600, {"test_heavy": cpu(40)}, cheap) for i in range(6)]
journal += [row(NOW - 3 * 86400 + 3600 + i * 36000, {"test_heavy": cpu(100)}, new) for i in range(6)]
journal += [row(NOW - 86400 + i * 600, {"test_new": cpu(60)}, new) for i in range(3)]
journal += [row(NOW - 3600 + i * 60, {"test_part": cpu(60)}, split) for i in range(4)]
journal += [row(NOW - 5 * 86400 + i * 30000, {"test_mid": cpu(20)}, cheap, worker=(i == 0)) for i in range(10)]
journal += [row(NOW - 4 * 86400, {"test_light": cpu(2, rc=1)}, cheap),
            row(NOW - 8 * 86400, {"test_mid": cpu(999)}, cheap)]
journal += [row(NOW - 4 * 86400 + i, {n: cpu(2) for n in ("test_light", "test_a", "test_b", "test_c", "test_d")}, cheap)
            for i in range(5)]


def save(rows):
    with open(os.environ["RUN_SUITES_JOURNAL"], "w") as handle:
        handle.write("".join(json.dumps(r) + "\n" for r in rows))


def ledger(rows):
    with open(os.environ["SPEND_LEDGER"], "w") as handle:
        json.dump({"owner": "Harness Doctor", "rows": rows}, handle)


save(journal)
ledger([])
sys.path.insert(0, os.path.join(root, "share"))
import suite_audit
import time_budget

suite_audit.FLOOR_MIN_DAY = 0.0


def collect(now=NOW):
    return suite_audit.collect(now, os.environ["RUN_SUITES_JOURNAL"], root)


out = collect()
found = {c["key"]: c for c in out["components"]}
check(found["alpha/test_mid"]["cpu_min_day"] == round(200 / 7 / 60.0, 2) and found["alpha/test_mid"]["runs"] == 10
      and found["alpha/test_mid"]["p50"] == 20 and found["alpha/test_light"]["runs"] == 6
      and found["alpha/test_light"]["p50"] == 2 and "workers 1 %" in out["head"],
      "a suite's price counts every runner's runs (the worker's too) over 7 days, an older run out,"
      " and its CPU a run reads passing runs: %s %s" % (found["alpha/test_mid"], out["head"]))
due = {p["suite"]["component"]: p for p in out["problems"]}
heavy = due["alpha/test_heavy"]["suite"]
check(heavy["at_once"] and heavy["due"] == "wall a run ×2.5 (40 → 100 s) since %s «heavy waits a minute»" % dear[:7]
      and heavy["commit"] == "%s «heavy waits a minute»" % dear[:7],
      "a wall rise of 2x and 30 s between commits is due at once and names the commit that changed the suite: %s" % heavy)
check(due["alpha/test_new"]["suite"]["at_once"]
      and due["alpha/test_new"]["suite"]["due"].startswith("new suite at ×30.0 the median suite a run, added in %s"
                                                            % new[:7])
      and not due["alpha/test_part"]["suite"]["at_once"]
      and due["alpha/test_part"]["suite"]["due"] == due["alpha/test_mid"]["suite"]["due"] == "never audited",
      "a new suite over 3x the median suite a run is due at once naming its commit; a suite split off another is not "
      "new: %s" % {k: p["suite"]["due"] for k, p in due.items()})
check(out["selection"][:4] == ["suite_audit:alpha:test_heavy", "suite_audit:alpha:test_part", "suite_audit:alpha:test_mid",
                               "suite_audit:alpha:test_new"] and out["status"] == "watch"
      and out["issues"][0] == [2.0, "alpha/test_heavy"],
      "the night's queue is by wall-min/day alone, a due-at-once suite included: %s" % out["selection"])
idle = [{"repo": "alpha", "name": name, "end": NOW - 60, "cpu": cpu_s, "wall": wall, "head": cheap, "worker": False,
         "ok": True} for name, cpu_s, wall in (("test_a.sh", 1.0, 300.0), ("test_b.sh", 50.0, 60.0))]
priced = suite_audit.price(idle, suite_audit.suites([repo]))
check([c["key"] for c in priced] == ["alpha/test_a", "alpha/test_b"] and priced[0]["wall_min_day"] == round(300 / 7 / 60.0, 2)
      and priced[0]["cpu_min_day"] < priced[1]["cpu_min_day"],
      "a suite idling most of its wall outranks a busier one, its CPU-min/day kept beside it: %s" % priced)
check(sorted(due["alpha/test_mid"]["suite"]["sources"]) == sorted(
    os.path.join(repo, "tests", n) for n in ("test_mid.sh", "helper.sh", os.path.join("lib", "common.sh"))),
      "a suite's sources are its file and the tests/ helpers it names: %s" % due["alpha/test_mid"]["suite"]["sources"])

held = open(os.environ["SPEND_LEDGER"]).read() if os.path.exists(os.environ["SPEND_LEDGER"]) else None
try:
    suite_audit.record(root, os.environ["RUN_SUITES_JOURNAL"], "alpha/test_mid", "kept", "", "", "night-x", [], NOW)
    refused = False
except SystemExit:
    refused = True
check(refused and (open(os.environ["SPEND_LEDGER"]).read() if os.path.exists(os.environ["SPEND_LEDGER"]) else None)
      == held, "a suite audit with no zero option is refused, nothing stored")
recorded = suite_audit.record(root, os.environ["RUN_SUITES_JOURNAL"], "alpha/test_mid", "kept", "fine as it is",
                              "removal saves 20 s a run; loses its checks", "night-x", [], NOW)
stored = json.load(open(os.environ["SPEND_LEDGER"]))["rows"]
check(stored == [recorded] and recorded["id"] == "suite:alpha/test_mid" and recorded["cpu_run"] == 20
      and recorded["wall_run"] == 20
      and recorded["verdict"] == "kept" and sorted(recorded["sources"]) == [
          "alpha/tests/helper.sh", "alpha/tests/lib/common.sh", "alpha/tests/test_mid.sh"],
      "an audit lands in Spend's ledger with its wall and CPU a run and each source's blob: %s" % recorded)
again = collect()
check("alpha/test_mid" not in {p["suite"]["component"] for p in again["problems"]}
      and again["proofs"]["alpha/test_mid"]["runs"] == 0
      and any(l[3].startswith("alpha/test_mid               0.5 wall-min/day ·") and l[3].endswith("wall-s a run · kept %s · 0 of 5 runs since" % recorded["audited_at"][:10])
              and l[1] == "d" for l in again["menu"]),
      "a kept audit closes the suite: no longer due, its menu row dim with the verdict: %s" % again["menu"])
check(suite_audit.restate([due["alpha/test_mid"]], {"suite:alpha/test_mid": recorded}) == []
      and suite_audit.restate([due["alpha/test_heavy"]], {"suite:alpha/test_heavy": dict(
          recorded, audited_at=datetime.datetime.fromtimestamp(NOW - 3 * 86400).astimezone().isoformat())})
      == [due["alpha/test_heavy"]],
      "a night close settles a suite audited after its reason arose, never one audited before its rise")
for name, text in (("helper.sh", "helper changed\n"),):
    write("tests/" + name, text)
check({p["suite"]["component"]: p["suite"]["due"] for p in collect()["problems"]}.get("alpha/test_mid")
      == "source changed", "an audited suite whose tests/ helper changed is due again")
write("tests/helper.sh", "helper\n")
ledger([dict(recorded, wall_run=20 / 2.0)])
rose = {p["suite"]["component"]: p for p in collect()["problems"]}.get("alpha/test_mid")
check(rose and rose["suite"]["due"] == "wall a run ×2.0 since audit"
      and suite_audit.restate([rose], {"suite:alpha/test_mid": dict(recorded, wall_run=20 / 2.0)}) == [rose],
      "wall a run at 2x the audit's is due again, and the audit it rose over does not settle it for a night close")
one_day = [r for r in journal if not {"test_heavy.sh", "test_mid.sh"} & set(r["suites"])]
one_day += [row(NOW - 6 * 86400 + i * 600, {"test_heavy": cpu(40)}, cheap) for i in range(6)]
one_day += [row(NOW - 2 * 86400 + i * 600, {"test_heavy": cpu(100)}, new) for i in range(6)]
one_day += [row(NOW - 5 * 86400 + i * 600, {"test_mid": cpu(20)}, cheap) for i in range(10)]
save(one_day)
spiked = {p["suite"]["component"]: p["suite"]["due"] for p in collect()["problems"]}
save(journal)
check(spiked.get("alpha/test_heavy") == "never audited" and "alpha/test_mid" not in spiked,
      "a rise held for one day is no rise, between commits or since the audit: it must span 2 days: %s" % spiked)
dropped = dict(recorded, sources=dict(recorded["sources"], **{"alpha/tests/gone.sh": "0" * 40}))
ledger([dropped])
gone = {p["suite"]["component"]: p for p in collect()["problems"]}.get("alpha/test_mid")
check(gone and gone["suite"]["due"] == "source changed" and suite_audit.restate([gone], {"suite:alpha/test_mid": dropped})
      == [gone], "a source the audit recorded and the suite no longer has is a change the old audit does not settle")
ledger([dict(recorded, wall_run=20 / 1.9)])
check("alpha/test_mid" not in {p["suite"]["component"] for p in collect()["problems"]}, "1.9x is not due")
ledger([recorded])
later = [row(NOW + 60 + i, {"test_mid": cpu(8)}, split) for i in range(5)]
save(journal + later)
proof = collect(NOW + 600)["proofs"]["alpha/test_mid"]
check(proof["proven"] and suite_audit.proof_text(proof) == "wall-s a run 20 → 8.0 (×0.40, 5 runs) · proven",
      "an audit is proven once the fastest of 5 runs after it reads 0.65x or less of its wall a run: %s" % proof)
save(journal + [row(NOW - 3 * 86400 + i, {"test_mid": cpu(250)}, cheap, worker=True) for i in range(30)]
     + [row(NOW - 3600 + i, {"test_mid": cpu(40)}, split) for i in range(suite_audit.RECENT_RUNS)])
cut = collect()
mid = {c["key"]: c for c in cut["components"]}["alpha/test_mid"]
check("workers 33 %" in cut["head"], "the workers' share prices their runs at the suite's CPU a run like the total it "
      "divides, so runs before a cut never read over 100 %%: %s" % cut["head"])
recorded = suite_audit.record(root, os.environ["RUN_SUITES_JOURNAL"], "alpha/test_mid", "kept", "split",
                              "removal saves 40 s a run; loses its checks", "night-x", [], NOW)
check(mid["p50"] == 40 and recorded["cpu_run"] == recorded["wall_run"] == 40 and mid["cpu_min_day"] == round(40 * 60 / 7 / 60.0, 2),
      "CPU a run reads the last %d passing runs and CPU-min/day prices the window's runs at it, so a suite cut or split "
      "days ago is queued and audited at its new cost: %s %s" % (suite_audit.RECENT_RUNS, mid, recorded))

loader = importlib.machinery.SourceFileLoader("harness_doctor", os.path.join(root, "bin", "harness-doctor"))
h = importlib.util.module_from_spec(importlib.util.spec_from_loader("harness_doctor", loader))
loader.exec_module(h)
ledger([])
save(journal)
section = collect()
problems = section.pop("problems")
document = {"problem_count": 0, "status": "ok", "as_of_s": int(NOW), "title": "Harness doctor: ok", "problems": [],
            "sections": [], "footer": "as of now"}
h.apply_speed(document, {"problems": problems, "suites": section, "menu": [], "head": "x"}, {"rows": []})
lines = h.menu_text(document).splitlines()
check(document["problem_count"] == 0 and all(p["group"] == "Suite audits" and p["speed"] for p in document["problems"])
      and "0\t\t\tSuite audits: watch · %s" % section["head"] in lines
      and section["head"].startswith("9 due · 4 wall-min/day, 4 CPU-min/day over 9 suites · workers 1 % · next: alpha/test_heavy")
      and "1\t\t\talpha/test_heavy             2.0 wall-min/day ·   2.0 CPU-min/day ·   40 wall-s a run · audit due: %s"
      % heavy["due"] in lines,
      "Harness lays Suite audits beside Spend: watch rows counted nowhere, its block: %s" % lines[2:6])

suite_audit.FLOOR_MIN_DAY = 1.0
floored = suite_audit.collect(NOW, os.environ["RUN_SUITES_JOURNAL"], root, {"alpha/test_light": {
    "reason": "names a gone file", "since": NOW - 60, "top": repo, "path": os.path.join(repo, "tests", "test_light.sh")}})
suite_audit.FLOOR_MIN_DAY = 0.0
check(floored["selection"] == ["suite_audit:alpha:test_heavy", "suite_audit:alpha:test_light"]
      and floored["head"].startswith("2 due · 7 under 1 wall-min/day skipped · ")
      and any(l[3].startswith("alpha/test_mid ") and l[3].endswith(" wall-s a run · under the 1 wall-min/day floor") for l in floored["menu"]),
      "a suite under 1 wall-min/day is never due whatever its reason, a dead one aside, and the head counts the ones "
      "skipped: %s %s" % (floored["selection"], floored["head"]))
sides = [[NOW - back * 86400 + 60 + i * 600 for i in range(3)] for back in (6, 2)]
machine = lambda after: [row(t, {n: cpu(w) for n in ("test_a", "test_b", "test_c")}, cheap)
                         for side, w in zip(sides, (10, after)) for t in side]
save(journal + machine(25))
busy = {p["suite"]["component"]: p["suite"] for p in collect()["problems"]}["alpha/test_heavy"]
save(journal + machine(12))
slower = {p["suite"]["component"]: p["suite"] for p in collect()["problems"]}["alpha/test_heavy"]
save(journal)
check(busy["due"] == "never audited" and not busy["at_once"]
      and slower["due"] == "wall a run ×2.1 (40 → 100 s, machine ×1.2) since %s «heavy waits a minute»" % dear[:7],
      "a rise counts only beyond the machine's slowdown, the median of the untouched suites' over the same spans: 40 "
      "→ 100 s while they ran 10 → 25 s is no rise, while they ran 10 → 12 s still one: %s / %s" % (busy, slower))
spans = [{"end": 0.0}, {"end": 100.0}], [{"end": 200.0}, {"end": 300.0}]
side = lambda w0, w1, changes: ([10.0, 20.0, 30.0, 210.0, 220.0, 230.0], [w0] * 3 + [w1] * 3, changes)
late = ([10.0, 20.0, 30.0, 60.0, 70.0, 80.0, 210.0, 220.0, 230.0], [1.0] * 3 + [2.0] * 3 + [4.0] * 3, [50.0])
mixed = dict({"u%d" % i: side(1.0, 2.0, []) for i in range(3)}, **{"t%d" % i: side(1.0, 1.0, [150.0]) for i in range(4)})
check(suite_audit.load(mixed, "x", *spans) == 2.0
      and suite_audit.load({"u": side(1.0, 2.0, []), "l1": late, "l2": late}, "x", *spans) == 2.0
      and suite_audit.load(mixed, "u0", *spans) == 1.0
      and suite_audit.load({k: side(2.0, 1.0, []) for k in ("a", "b", "c")}, "x", *spans) == 1.0,
      "the load leaves out suites changed between the runs compared, reads a suite changed inside the before span "
      "since its change, needs 3 controls besides the suite itself, and never reads under 1")

item = {"ref": "night-x", "ids": ["test_slow:alpha:test_mid"], "class": time_budget.improvement_class(
    "suite_audit", "suite_audit:alpha:test_mid"), "spend_m": 1.5, "lines": [3, 9], "merged": True}
night = {"started": NOW - 30, "ended": NOW, "hours": 0.0, "improvements": [item]}
save(journal + later[:4])
check(item["class"] == "suite_run" and time_budget.roi_lines([night], NOW + 600)[0]
      == "roi · night-x · alpha/test_mid · 1.5M · +3/-9 · wall-s/run: 4 of 5 since",
      "a suite improvement waits for 5 runs after the night, not a full day")
save(journal + later[:4] + [row(NOW + 120 + i, {"test_mid": cpu(1, rc=1)}, split) for i in range(5)])
check(time_budget.roi_lines([night], NOW + 600)[0] == "roi · night-x · alpha/test_mid · 1.5M · +3/-9 · wall-s/run: 4 of 5 since",
      "failed runs stop early and are no proof sample: cheap failures after a night never prove it")
save(journal + later)
check(time_budget.roi_lines([night], NOW + 600)
      == ["roi · night-x · alpha/test_mid · 1.5M · +3/-9 · 20 → 8.0 wall-s/run · proven · 0.3 suite-min/day",
          "roi · night: improvements 1.5M · gained 0.0 min/day · 0.3 suite-min/day · 1 proven per unit",
          "roi · last 1 nights: improvements 1.5M · gained 0.0 min/day · 0.3 suite-min/day · 1 proven per unit"],
      "with 5 runs after it the night's roi line reads its per-unit before → after, and its gain in the unit's own "
      "daily measure: 12 wall-s a run × its 10 runs in the 7 days before: %s" % time_budget.roi_lines([night], NOW + 600))
save(journal + [row(NOW + 60 + i, {"test_mid": cpu(w)}, split) for i, w in enumerate((8, 30, 30, 30, 30))])
check(time_budget.unit_proof(item, NOW - 30, NOW, NOW + 600)["text"] == "20 → 30 wall-s/run · not proven",
      "one lucky fast run after the night proves nothing: a suite compares medians, never the fastest run")
controls = ("test_a", "test_b", "test_c")
busy = [row(NOW + 60 + i, {n: cpu(4) for n in controls}, cheap) for i in range(5)]
busy += [row(NOW - 5 * 86400 + 150000 + i * 30000, {n: cpu(2) for n in controls}, cheap) for i in range(5)]
save(journal + [row(NOW + 60 + i, {"test_mid": cpu(24)}, split) for i in range(5)] + busy)
loaded = time_budget.unit_proof(item, NOW - 30, NOW, NOW + 600)
save(journal + [row(NOW + 60 + i, {"test_mid": cpu(25)}, split) for i in range(5)] + busy[:3] + busy[5:])
check(loaded["text"] == "20 → 24 wall-s/run · load ×2.00 · proven · 0.2 suite-min/day" and loaded["load"] == 2.0
      and time_budget.unit_proof(item, NOW - 30, NOW, NOW + 600)["text"] == "20 → 25 wall-s/run · not proven",
      "a suite is judged against the suites the fix never named in the same windows: 20 → 24 s while three untouched "
      "suites ran 2 → 4 s is a gain, priced at 20 - 24/2 s a run; under 3 such suites with N runs, none is matched: %s"
      % loaded)
night_file = os.path.join(work, "night-slow.json")
with open(night_file, "w") as handle:
    json.dump({"jobs": [{"ref": "night-x", "commits": [{"repo": "alpha", "hash": "0123456789abcdef"}]}]}, handle)
code = dict(item, files=[["alpha", "tests/test_mid.sh"]])
slow_night = [(night_file, dict(night, id="n-slow", improvements=[code, dict(code, ref="night-m", files=[["alpha", "a.md"]])]))]
save(journal + [row(NOW + 60 + i, {"test_mid": cpu(30)}, split) for i in range(5)])
slow = time_budget.slower_fixes(slow_night, NOW + 600)
slow_wins, won = {}, {}
time_budget.roi_lines([slow_night[0][1]], NOW + 600, verdicts=slow_wins)
save(journal + later)
time_budget.roi_lines([dict(night, id="n-won", improvements=[item, dict(item, ref="night-m", files=[["alpha", "a.md"]])])],
                      NOW + 600, verdicts=won)
check(slow_wins == {"n-slow": {0: {"pending": False, "gain": 0.0, "proven": False, "slower": True}}}
      and won == {"n-won": {0: {"pending": False, "gain": 0.0, "proven": False, "slower": False}}},
      "the «Скорость» verdicts are the roi lines' own measures: a proven suite's suite-min (walls of suites run side "
      "by side, no wait) neither adds minutes nor a ✓ beside them; a fix measured slower as such, a measurement fix "
      "never: %s %s"
      % (slow_wins, won))
save(journal + [row(NOW + 60 + i, {"test_mid": cpu(30)}, split) for i in range(5)])
save(journal + [row(NOW + 60 + i, {"test_mid": cpu(30)}, split) for i in range(5)] + busy)
check(slow == [{"ref": "night-x", "night": "n-slow", "ids": ["test_slow:alpha:test_mid"], "loss": 0.2,
                "spans": ["alpha/test_mid 20 → 30 wall-s/run"], "daily": "suite-min/day",
                "files": [["alpha", "tests/test_mid.sh"]], "commits": ["alpha@0123456789ab"]}]
      and time_budget.slower_fixes(slow_night, NOW + 600) == [],
      "a landed fix whose own suite ran over 1.3x its wall after it is measured slower, naming its job's commits; a "
      "measurement fix never is, nor a suite as slow as the untouched ones beside it: %s" % slow)
save(journal + [row(NOW + 3600 + i, {"test_mid": cpu(30)}, split) for i in range(5)] + busy[5:]
     + [row(NOW + 60 + i, {n: cpu(2) for n in controls}, cheap) for i in range(10)]
     + [row(NOW + 3600 + i, {n: cpu(4) for n in controls}, cheap) for i in range(5)])
check(time_budget.slower_fixes(slow_night, NOW + 4000) == [],
      "a suite is load-matched against the untouched suites' runs between its own compared runs, not their first runs "
      "after the night: 20 → 30 s an hour later, while they ran 2 → 4 s, is no slowdown")
whole = dict(code, ids=["time_floor:suite_run"])
save(journal + [row(NOW + 60 + i, {"test_mid": cpu(20), "test_a": cpu(10)}, split) for i in range(5)])
check(time_budget.unit_proof(whole, NOW - 30, NOW, NOW + 600)["slower"] == {}
      and time_budget.runtime_change(dict(whole, files=[["alpha", "share/time_budget.py"],
                                                        ["alpha", "tests/test_time_budget.sh"]])) is False,
      "a fix naming no suite whose code is suite files only is judged on those suites (test_a 2 → 10 s is not its "
      "slowdown); a measurer with its own suite changes no unit's runtime")
save(journal + [row(NOW + 60 + i, {"test_mid": cpu(10, shards=4) if i % 2 else cpu(60)}, split) for i in range(10)])
check(time_budget.slower_fixes(slow_night, NOW + 600) == []
      and time_budget.unit_proof(item, NOW - 30, NOW, NOW + 600)["after"] == 10,
      "a sharded suite is measured on its sharded runs: the whole runs of a full machine (60 s) are no slowdown")
save(journal + later)
check(time_budget.roi_lines([night, dict(night, improvements=[dict(item, ref="night-y")])], NOW + 600)[0]
      == "roi · night-y · alpha/test_mid · 1.5M · +3/-9 · 20 → 8.0 wall-s/run · proven · shared with night-x",
      "a suite's drop is claimed once: a later fix of the same suite reads shared")
unnamed, seen = dict(item, ids=["time_floor:suite_run"], files=[["alpha", "share/runner.py"]]), {}
check(time_budget.unit_proof(unnamed, NOW - 30, NOW, NOW + 600)["text"] == "no unit named, no load control: unmeasured"
      and time_budget.roi_lines([dict(night, id="n-all", improvements=[unnamed])], NOW + 600, verdicts=seen)[:2]
      == ["roi · night-x · suites running · 1.5M · +3/-9 · no unit named, no load control: unmeasured",
          "roi · night: improvements 0.0M · gained 0.0 min/day · 1 unmeasured"]
      and seen == {"n-all": {0: {"pending": False, "gain": 0.0, "proven": False, "slower": False}}},
      "a suite fix naming no suite and changing code beyond suites has no untouched suite to match load against: every "
      "suite's drop under a quieter machine is no gain of its own (night 7777 read 2050 suite-min/day so): %s" % seen)
remeasured = dict(item, files=[["alpha", "share/suite_audit.py"], ["alpha", "tests/test_heavy.sh"]])
check(time_budget.roi_lines([dict(night, improvements=[remeasured])], NOW + 600)
      == ["roi · night-x · alpha/test_mid · 1.5M · +3/-9 lines · 20 → 8.0 wall-s/run · measurement fix",
          "roi · night: improvements 1.5M · gained 0.0 min/day · 1 measurement fix",
          "roi · last 1 nights: improvements 1.5M · gained 0.0 min/day · nothing measured yet"]
      and time_budget.roi_lines([dict(night, improvements=[dict(remeasured, files=[["alpha", "tests/test_mid.sh"]])])],
                                NOW + 600)[0].endswith("proven · 0.3 suite-min/day"),
      "a suite's drop is a measurement fix unless the fix touched that suite's own code")
gone = dict(item, ids=["suite_audit:alpha:test_gone"])
check(time_budget.unit_proof(gone, NOW - 30, NOW, NOW + 600)["gone"]
      and time_budget.roi_lines([dict(night, improvements=[gone])], NOW + 600)[0]
      == "roi · night-x · alpha/test_gone · 1.5M · +3/-9 lines · measurement fix"
      and time_budget.roi_lines([dict(night, improvements=[dict(gone, files=[["alpha", "code.py"]])])], NOW + 600)[0]
      == "roi · night-x · alpha/test_gone · 1.5M · +3/-9 lines · pending a full day",
      "a named suite that no longer exists proves nothing per unit: a measurement fix, or the day totals when the fix "
      "changed runtime code")
events = os.path.join(work, "harness", "events")
os.makedirs(events)
hooks = [["h", NOW - 3600 + i, "~", "PreToolUse", "gate.sh", 200, "Bash", "x"] for i in range(50)]
hooks += [["h", NOW + 60 + i, "~", "PreToolUse", "gate.sh", 80, "Bash", "x"] for i in range(50)]
hooks += [["h", t + i, "~", "Stop", "stop.sh", 900, "", "x"] for t in (NOW - 3600, NOW + 60) for i in range(50)]
hooks += [["h", NOW - 3000 + i, "~", "PreToolUse", "~/.claude/hooks/other.sh fast", 1000, "Bash", "x"]
          for i in range(50)]
hooks += [["h", NOW + 60 + i, "~", "PreToolUse", "~/.claude/hooks/other.sh fast", 100, "Bash", "x"]
          for i in range(50)]
hooks += [["h", NOW - 3000 + i, "~", "PreToolUse", "~/.claude/hooks/gone.sh", 1000, "Bash", "x"] for i in range(50)]
for day in {time_budget.local_day(r[1]) for r in hooks}:
    with open(os.path.join(events, day + ".jsonl"), "w") as handle:
        handle.write("".join(json.dumps(r, separators=(",", ":")) + "\n" for r in hooks
                             if time_budget.local_day(r[1]) == day))
both = ["opportunity:hooks/gate.sh", "opportunity:hooks/other.sh fast"]
shown = time_budget.unit_proof({"class": "hooks", "ids": both}, NOW - 30, NOW, NOW + 600)
check(shown["text"] == "600 → 90 ms/call · proven · 0.1 min/day" and shown["samples"] == 100
      and time_budget.unit_proof({"class": "hooks", "ids": ["opportunity:hooks/gate.sh"]}, NOW - 30, NOW,
                                 NOW + 600)["text"] == "200 → 80 ms/call · proven · 0.0 min/day"
      and time_budget.unit_proof({"class": "hooks", "ids": ["opportunity:hooks/other.sh fast"]}, NOW - 30, NOW,
                                 NOW + 600)["gain"] == 0.1
      and time_budget.unit_proof({"class": "hooks", "ids": ["opportunity:hooks/gone.sh"]}, NOW - 30, NOW,
                                 NOW + 86400)["gone"]
      and time_budget.unit_proof({"class": "hooks", "ids": ["opportunity:hooks/gone.sh"]}, NOW - 30, NOW,
                                 NOW + 600)["proven"] is None
      and time_budget.unit_proof({"class": "hooks", "ids": both[:1]}, NOW - 30, NOW + 100, NOW + 600)["proven"] is None
      and time_budget.unit_proof({"class": "hooks", "ids": ["regression:hooks"]}, NOW - 30, NOW, NOW + 600)["unmeasured"]
      and time_budget.unit_proof({"class": "retries", "ids": []}, NOW - 30, NOW, NOW + 600) is None
      and time_budget.unit_proof({"class": "slot", "ids": []}, NOW - 30, NOW, NOW + 600) is None,
      "a hook improvement reads ms a call per script (Stop hooks apart, only the hooks its ids name) from 50 calls "
      "after it, its gain each key's ms saved × its calls a day in the 7 days before; a named hook absent a full day is gone; a class with no "
      "unit, or no sample of it before the night, keeps the day totals; a hook fix naming none has no control: %s" % shown)
h1 = {"ref": "night-h1", "class": "hooks", "ids": ["opportunity:hooks/other.sh fast"], "spend_m": 1.0,
      "lines": [1, 1], "merged": True}
shown = time_budget.roi_lines([dict(night, improvements=[h1]),
                               dict(night, improvements=[dict(h1, ref="night-h2", ids=both)])], NOW + 600)
check(shown[0] == "roi · night-h2 · gate.sh, other.sh fast · 1.0M · +1/-1 · 600 → 90 ms/call · proven · 0.0 min/day · shared with night-h1"
      and shown[-1] == "roi · last 2 nights: improvements 2.0M · gained 0.1 min/day · 0.1 min/day per 1M",
      "a later fix gains only the hooks no earlier fix claimed: %s" % shown)
late = [["h", NOW - 5000 + i, "~", "PreToolUse", "late.sh", 1000, "Bash", "x"] for i in range(100)]
late += [["h", NOW - 1000 + i, "~", "PreToolUse", "late.sh", 100, "Bash", "x"] for i in range(50)]
late += [["h", NOW + 60 + i, "~", "PreToolUse", "late.sh", 100, "Bash", "x"] for i in range(50)]
for r in late:
    with open(os.path.join(events, time_budget.local_day(r[1]) + ".jsonl"), "a") as handle:
        handle.write(json.dumps(r, separators=(",", ":")) + "\n")
check(time_budget.unit_proof({"class": "hooks", "ids": ["opportunity:hooks/late.sh"]}, NOW - 30, NOW, NOW + 600)["text"]
      == "100 → 100 ms/call · not proven",
      "a drop that came before the night is not its gain: the first N calls after it against the newest N before it")
far = NOW + 20 * 86400
skew = [["h", far - 3600 + i, "~", "PreToolUse", "skew.sh", 1 if i < 24 else 10000, "Bash", "x"] for i in range(50)]
skew += [["h", far + 60 + i, "~", "PreToolUse", "skew.sh", 1, "Bash", "x"] for i in range(50)]
for r in skew:
    with open(os.path.join(events, time_budget.local_day(r[1]) + ".jsonl"), "a") as handle:
        handle.write(json.dumps(r, separators=(",", ":")) + "\n")
check(time_budget.unit_proof({"class": "hooks", "ids": ["opportunity:hooks/skew.sh"]}, far - 30, far, far + 600)["text"]
      == "10000 → 1.0 ms/call · 1.2 over the 0.6 min/day before: unmeasured",
      "a proof can never gain more than its measure's whole day before the night: a median of 10 s over 24 calls of "
      "1 ms claims 1.2 min/day of the 0.6 the hooks spent, unmeasured")
hook_rows = lambda at, name, was, now_: ([["h", at - 3600 + i, "~", "PreToolUse", name, was, "Bash", "x"] for i in range(50)]
                                         + [["h", at + 60 + i, "~", "PreToolUse", name, now_, "Bash", "x"] for i in range(50)])
fix, judged = {"ref": "night-f", "class": "hooks", "ids": ["opportunity:hooks/fix.sh"], "spend_m": 1.0, "lines": [1, 1],
               "merged": True}, {}
for name, at, control in (("in band", NOW + 40 * 86400, 100), ("no control", NOW + 60 * 86400, None),
                          ("quieter", NOW + 80 * 86400, 40)):
    for r in hook_rows(at, "fix.sh", 1000, 100) + [r for c in ("c1.sh", "c2.sh", "c3.sh") if control
                                                   for r in hook_rows(at, c, 100, control)]:
        with open(os.path.join(events, time_budget.local_day(r[1]) + ".jsonl"), "a") as handle:
            handle.write(json.dumps(r, separators=(",", ":")) + "\n")
    time_budget.roi_lines([dict(night, id=name, started=at - 30, ended=at, improvements=[fix])], at + 600, verdicts=judged)
check(judged == {"in band": {0: {"pending": False, "gain": 0.1, "proven": True, "slower": False}},
                 "no control": {0: {"pending": False, "gain": 0.0, "proven": False, "slower": False}},
                 "quieter": {0: {"pending": False, "gain": 0.0, "proven": False, "slower": False}}},
      "a «Скорость» gain is load-matched: 1000 → 100 ms/call proves 0.1 min/day beside three untouched hooks at "
      "100 → 100 ms, never with fewer than 3 of them (load fixed at 1) nor beside ones at 100 → 40 ms (load ×0.40, "
      "outside the suite proof ratio either way): %s" % judged)
flat = [{"wall": w, "cpu": 20.0, "head": h, "end": NOW + i * 36000, "ok": True}
        for i, (w, h) in enumerate([(40.0, "a")] * 6 + [(100.0, "b")] * 6)]
check(suite_audit.jump(flat) and suite_audit.jump(flat)["before"] == 40 and suite_audit.proof(
    {"history": [dict(f, wall=30.0) for f in flat[:5]]},
    {"audited_at": datetime.datetime.fromtimestamp(NOW - 1).astimezone().isoformat(), "wall_run": 100.0,
     "cpu_run": 20.0})["proven"],
      "a suite whose wall rises or falls at flat CPU is due and proven by its wall")
save(journal + later)
idle = dict(item, ids=["opportunity:test-health/idle/alpha/test_mid"])
fan = dict(item, ids=["opportunity:test-health/fan-out/alpha/share/x.sh"], files=[["alpha", "share/x.sh"]])
check(time_budget.unit_names(idle) == {"alpha/test_mid"} and time_budget.unit_names(fan) == {"alpha/share/x.sh"}
      and time_budget.roi_lines([dict(night, improvements=[idle])], NOW + 600)[0]
      == "roi · night-x · alpha/test_mid · 1.5M · +3/-9 · 20 → 8.0 wall-s/run · proven · 0.3 suite-min/day"
      and time_budget.unit_proof(fan, NOW - 30, NOW, NOW + 600) is None
      and time_budget.unit_proof(dict(item, ids=["opportunity:test-health/retests"]), NOW - 30, NOW, NOW + 600) is None
      and time_budget.roi_lines([dict(night, improvements=[fan])], NOW + 600)[0]
      == "roi · night-x · alpha/share/x.sh · 1.5M · +3/-9 lines · pending a full day",
      "a test health fix is proven on the suite it names, and one that cuts runs (retests, a file's fan-out) on the "
      "class's day totals, the file named: %s" % time_budget.roi_lines([dict(night, improvements=[idle, fan])], NOW + 600))
gates = []
for start, gate in ((NOW - 30 - 7 * 86400, "g.sh"), (NOW - 30 - 7 * 86400, "other.sh"), (NOW + 60, "other.sh")):
    gates += [{"at": start + (k + 0.5) * 86400, "sid": "%s%03d" % (gate[:5], k), "gate": gate, "tool_use_id": ""} for k in range(7)]
calls = [["c", g["at"] + 30, "~", "Bash", 0, 1, "c", "ok%d" % i, g["sid"], 1] for i, g in enumerate(gates)]
for c in calls:
    with open(os.path.join(events, time_budget.local_day(c[1]) + ".jsonl"), "a") as handle:
        handle.write(json.dumps(c, separators=(",", ":")) + "\n")
time_budget.refusal_rows = lambda lo, hi: [dict(g) for g in gates if lo <= g["at"] < hi]
week = NOW + 7 * 86400 + 120
fixed = time_budget.unit_proof({"class": "refusal", "ids": ["opportunity:refusal/g.sh"]}, NOW - 30, NOW, week)
still = time_budget.unit_proof({"class": "refusal", "ids": ["opportunity:refusal/other.sh"]}, NOW - 30, NOW, week)
check(time_budget.improvement_class("opportunity", "opportunity:refusal/g.sh") == "refusal"
      and fixed["text"] == "30 → 0.0 s/day · proven · 0.5 min/day" and still["proven"] is False
      and time_budget.unit_proof({"class": "refusal", "ids": ["opportunity:refusal/g.sh"]}, NOW - 30, NOW,
                                 NOW + 3 * 86400)["proven"] is None,
      "a gate's refusal fix is proven by its recovery seconds a day, a silent day counting 0, a week after the night: "
      "%s %s" % (fixed, still))
save(journal)
fresh = suite_audit.record(root, os.environ["RUN_SUITES_JOURNAL"], "alpha/test_mid", "kept", "fine",
                           "removal saves 20 s a run; loses its checks", "night-x", [], NOW)
ledger([dict(fresh, audited_at=datetime.datetime.fromtimestamp(NOW - 3600).astimezone().isoformat())])
night_branch = "night/n/harness-speed-suite-audit-alpha-test-mid-20261012T235210Z-48fc"
git("checkout", "-qb", night_branch)
write("tests/helper.sh", "helper sped up\n")
git("commit", "-qam", "the audit's own landing", at=NOW - 1800)
git("checkout", "-q", "-")
git("merge", "-q", "--ff-only", night_branch, at=NOW - 1800)
reason = lambda: {p["suite"]["component"]: p["suite"]["due"] for p in collect()["problems"]}.get("alpha/test_mid")
landed = reason()
write("tests/helper.sh", "a local edit\n")
dirty = reason()
write("tests/helper.sh", "a chat's edit\n")
git("commit", "-qam", "a chat's edit", at=NOW - 900)
check(landed is None and dirty == reason() == "source changed",
      "a helper only a Speed audit landing moved leaves the audit closed; an uncommitted edit or a commit main took any "
      "other way reopens it: %s %s" % (landed, dirty))
print(count[0])
EOF
) || { printf 'FAIL: the Suite audits block misjudged its fixture\n' >&2; exit 1; }

printf 'PASS: %s asserts; Suite audits price every suite over every runner, judge audits due by never/source blob/2x wall a run over a 1 wall-min/day floor, a load-matched rise between commits or a new heavy suite at once naming its commit (a split is not new), queue the night, close a kept audit with its proof, settle it for a night close, lay their block in Harness; a night improvement is proven per unit (suite wall a run, hook ms a call, gate recovery s a day; test health by its suite or file) once N samples follow it\n' "$asserts"
