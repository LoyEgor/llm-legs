#!/usr/bin/env bash
. "${BASH_SOURCE%"${BASH_SOURCE##*/}"}lib/suite-journal.sh"
# share/suite_audit.py, the Suite audits block of the Harness doctor, and time_budget's per-unit proof, off a fixture
# repository and run-suites journal: pricing over every runner, the due rules (never, a source
# blob, 1.5x CPU a run, a rise between commits naming its commit, a new heavy suite, a split that is not new), the
# night's queue, a kept audit closing it with its proof, the restate a night close reads, the Harness menu block and
# a night improvement proven per unit (suite CPU a run, hook ms a call) once N samples follow it. Fixture directories
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
journal += [row(NOW - 2 * 86400 + i * 600, {"test_heavy": cpu(100)}, new) for i in range(6)]
journal += [row(NOW - 86400 + i * 600, {"test_new": cpu(60)}, new) for i in range(3)]
journal += [row(NOW - 3600 + i * 60, {"test_part": cpu(60)}, split) for i in range(4)]
journal += [row(NOW - 5 * 86400 + i * 600, {"test_mid": cpu(20)}, cheap, worker=(i == 0)) for i in range(10)]
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
check(heavy["at_once"] and heavy["due"] == "CPU a run ×2.5 (40 → 100 s) since %s «heavy waits a minute»" % dear[:7]
      and heavy["commit"] == "%s «heavy waits a minute»" % dear[:7],
      "a rise of 1.5x and 30 s between commits is due at once and names the commit that changed the suite: %s" % heavy)
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
      "the night's queue is by CPU-min/day alone, a due-at-once suite included: %s" % out["selection"])
check(sorted(due["alpha/test_mid"]["suite"]["sources"]) == sorted(
    os.path.join(repo, "tests", n) for n in ("test_mid.sh", "helper.sh", os.path.join("lib", "common.sh"))),
      "a suite's sources are its file and the tests/ helpers it names: %s" % due["alpha/test_mid"]["suite"]["sources"])

recorded = suite_audit.record(root, os.environ["RUN_SUITES_JOURNAL"], "alpha/test_mid", "kept", "fine as it is",
                              "night-x", [], NOW)
stored = json.load(open(os.environ["SPEND_LEDGER"]))["rows"]
check(stored == [recorded] and recorded["id"] == "suite:alpha/test_mid" and recorded["cpu_run"] == 20
      and recorded["verdict"] == "kept" and sorted(recorded["sources"]) == [
          "alpha/tests/helper.sh", "alpha/tests/lib/common.sh", "alpha/tests/test_mid.sh"],
      "an audit lands in Spend's ledger with its CPU a run and each source's blob: %s" % recorded)
again = collect()
check("alpha/test_mid" not in {p["suite"]["component"] for p in again["problems"]}
      and again["proofs"]["alpha/test_mid"]["runs"] == 0
      and any(l[3].endswith("alpha/test_mid · kept %s · 0 of 5 runs since" % recorded["audited_at"][:10])
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
ledger([dict(recorded, cpu_run=20 / 1.5)])
rose = {p["suite"]["component"]: p for p in collect()["problems"]}.get("alpha/test_mid")
check(rose and rose["suite"]["due"] == "CPU a run ×1.5 since audit"
      and suite_audit.restate([rose], {"suite:alpha/test_mid": dict(recorded, cpu_run=20 / 1.5)}) == [rose],
      "CPU a run at 1.5x the audit's is due again, and the audit it rose over does not settle it for a night close")
dropped = dict(recorded, sources=dict(recorded["sources"], **{"alpha/tests/gone.sh": "0" * 40}))
ledger([dropped])
gone = {p["suite"]["component"]: p for p in collect()["problems"]}.get("alpha/test_mid")
check(gone and gone["suite"]["due"] == "source changed" and suite_audit.restate([gone], {"suite:alpha/test_mid": dropped})
      == [gone], "a source the audit recorded and the suite no longer has is a change the old audit does not settle")
ledger([dict(recorded, cpu_run=20 / 1.4)])
check("alpha/test_mid" not in {p["suite"]["component"] for p in collect()["problems"]}, "1.4x is not due")
ledger([recorded])
later = [row(NOW + 60 + i, {"test_mid": cpu(8)}, split) for i in range(5)]
save(journal + later)
proof = collect(NOW + 600)["proofs"]["alpha/test_mid"]
check(proof["proven"] and suite_audit.proof_text(proof) == "CPU-s a run 20 → 8.0 (×0.40, 5 runs) · proven",
      "an audit is proven once 5 runs after it read 0.75x or less of its CPU a run: %s" % proof)
save(journal + [row(NOW - 3 * 86400 + i, {"test_mid": cpu(250)}, cheap, worker=True) for i in range(30)]
     + [row(NOW - 3600 + i, {"test_mid": cpu(40)}, split) for i in range(suite_audit.RECENT_RUNS)])
cut = collect()
mid = {c["key"]: c for c in cut["components"]}["alpha/test_mid"]
check("workers 33 %" in cut["head"], "the workers' share prices their runs at the suite's CPU a run like the total it "
      "divides, so runs before a cut never read over 100 %%: %s" % cut["head"])
recorded = suite_audit.record(root, os.environ["RUN_SUITES_JOURNAL"], "alpha/test_mid", "kept", "split", "night-x", [],
                              NOW)
check(mid["p50"] == 40 and recorded["cpu_run"] == 40 and mid["cpu_min_day"] == round(40 * 60 / 7 / 60.0, 2),
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
      and section["head"].startswith("9 due · 4 CPU-min/day over 9 suites · workers 1 % · next: alpha/test_heavy")
      and "1\t\t\t  2.0 CPU-min/day ·   70 CPU-s a run · alpha/test_heavy · audit due: %s" % heavy["due"] in lines,
      "Harness lays Suite audits beside Spend: watch rows counted nowhere, its block: %s" % lines[2:6])

item = {"ref": "night-x", "ids": ["test_slow:alpha:test_mid"], "class": time_budget.improvement_class(
    "suite_audit", "suite_audit:alpha:test_mid"), "spend_m": 1.5, "lines": [3, 9], "merged": True}
night = {"started": NOW - 30, "ended": NOW, "hours": 0.0, "improvements": [item]}
save(journal + later[:4])
check(item["class"] == "suite_run" and time_budget.roi_lines([night], NOW + 600)[0]
      == "roi · night-x · 1.5M · +3/-9 · CPU-s/run: 4 of 5 since",
      "a suite improvement waits for 5 runs after the night, not a full day")
save(journal + later[:4] + [row(NOW + 120 + i, {"test_mid": cpu(1, rc=1)}, split) for i in range(5)])
check(time_budget.roi_lines([night], NOW + 600)[0] == "roi · night-x · 1.5M · +3/-9 · CPU-s/run: 4 of 5 since",
      "failed runs stop early and are no proof sample: cheap failures after a night never prove it")
save(journal + later)
check(time_budget.roi_lines([night], NOW + 600)
      == ["roi · night-x · 1.5M · +3/-9 · 20 → 8.0 CPU-s/run · proven",
          "roi · night: improvements 1.5M · gained 0.0 min/day · 1 proven per unit",
          "roi · last 1 nights: improvements 1.5M · gained 0.0 min/day · 1 proven per unit"],
      "with 5 runs after it the night's roi line reads its per-unit before → after: %s"
      % time_budget.roi_lines([night], NOW + 600))
events = os.path.join(work, "harness", "events")
os.makedirs(events)
hooks = [["h", NOW - 3600 + i, "~", "PreToolUse", "gate.sh", 200, "Bash", "x"] for i in range(50)]
hooks += [["h", NOW + 60 + i, "~", "PreToolUse", "gate.sh", 80, "Bash", "x"] for i in range(50)]
hooks += [["h", t + i, "~", "Stop", "stop.sh", 900, "", "x"] for t in (NOW - 3600, NOW + 60) for i in range(50)]
for day in {time_budget.local_day(r[1]) for r in hooks}:
    with open(os.path.join(events, day + ".jsonl"), "w") as handle:
        handle.write("".join(json.dumps(r, separators=(",", ":")) + "\n" for r in hooks
                             if time_budget.local_day(r[1]) == day))
shown = time_budget.unit_proof({"class": "hooks", "ids": ["time_floor:hooks"]}, NOW - 30, NOW, NOW + 600)
check(shown["text"] == "200 → 80 ms/call · proven" and shown["samples"] == 50
      and time_budget.unit_proof({"class": "hooks", "ids": []}, NOW - 30, NOW + 100, NOW + 600)["proven"] is None
      and time_budget.unit_proof({"class": "retries", "ids": []}, NOW - 30, NOW, NOW + 600) is None
      and time_budget.unit_proof({"class": "slot", "ids": []}, NOW - 30, NOW, NOW + 600) is None,
      "a hook improvement reads ms a call per script (Stop hooks apart) from 50 calls after it; a class with no unit, "
      "or no sample of it before the night, keeps the day totals: %s" % shown)
print(count[0])
EOF
) || { printf 'FAIL: the Suite audits block misjudged its fixture\n' >&2; exit 1; }

printf 'PASS: %s asserts; Suite audits price every suite over every runner, judge audits due by never/source blob/1.5x CPU a run, a rise between commits or a new heavy suite at once naming its commit (a split is not new), queue the night, close a kept audit with its proof, settle it for a night close, lay their block in Harness; a night improvement is proven per unit (suite CPU a run, hook ms a call) once N samples follow it\n' "$asserts"
