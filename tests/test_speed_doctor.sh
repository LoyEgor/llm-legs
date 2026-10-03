#!/usr/bin/env bash
. "${BASH_SOURCE%"${BASH_SOURCE##*/}"}lib/suite-journal.sh"
# bin/speed-doctor, the Speed block of the Harness doctor, over the 2026-09-29 .. 10-02 calibration transcripts folded
# by Harness's own C1 reader: the headline, the R band, a partition that sums to it, the backlog and its scores, the
# quality rule, presence, judging, the merge into Harness's document with each rule counted once, the moved heavy-test
# and hot-hook opportunities, the offset reads, the journal prune and Harness's exec. Fixture directories only.
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

asserts=$(python3 - "$ROOT" "$WORK" <<'EOF'
import copy, fcntl, gzip, glob, importlib.machinery, importlib.util, json, os, shutil, subprocess, sys, time

root, work = sys.argv[1], sys.argv[2]
count = [0]


def check(cond, what):
    count[0] += 1
    if not cond:
        print("FAIL: %s" % what, file=sys.stderr)
        sys.exit(1)


sys.path.insert(0, os.path.join(root, "tests", "lib"))
from speed_calibration import HI, LO, fold, harness
h = harness(root)
fold(h, root, work)

ledger = os.path.join(work, "ledger.json")
with open(ledger, "w") as handle:
    json.dump({"owner": "Harness Doctor", "rows": [], "blind_spots": []}, handle)
base = {"HOME": os.path.join(work, "home"), "HARNESS_DOCTOR_DIR": os.path.join(work, "harness"),
        "DOCTORS_DIR": os.path.join(work, "doctors"), "WORKER_STATS_DIR": os.path.join(work, "worker-stats"),
        "CODE_DOCTOR_DIR": os.path.join(work, "code"), "HARNESS_LEDGER": ledger,
        "CODE_LEDGER": os.path.join(work, "code-ledger.json"), "STATUSLINE_CACHE_DIR": os.path.join(work, "sl"),
        "HARNESS_REPOS_DIR": os.path.join(work, "repos"), "SPEED_DOCTOR_NOW": str(HI), "PATH": os.environ["PATH"]}


def speed(folder, *args, **env):
    started = time.monotonic()
    out = subprocess.run([os.path.join(root, "bin", "speed-doctor")] + list(args or ["--json"]),
                         env=dict(base, SPEED_DOCTOR_DIR=os.path.join(work, folder), **env),
                         capture_output=True, text=True)
    wall = time.monotonic() - started
    if "--json" in (args or ["--json"]):
        return json.loads(out.stdout), wall
    return out, wall


def counted_once(document):
    """Each (rule, ident) is loud at most once, and no rule Speed covers is loud beside it."""
    loud = [(p["rule"], p.get("ident")) for p in document["problems"] if p["state"] in h.LOUD_STATES]
    covered = {(rule, ident) for rule, ident, _ in (document.get("speed") or {}).get("covers") or ()}
    return (len(loud) == len(set(loud)) == document["problem_count"]
            and not [k for k in loud if k in covered or (k[0], "*") in covered])


doc, wall = speed("speed")
check(doc["status"] == "ok" and doc["problem_count"] == 0 and not {"contract", "doctor", "title"} & set(doc),
      "the calibration section has nothing counted and no document keys of its own: %s" % doc["status"])
check(wall <= 2.0, "speed-doctor reads its inputs in <= 2 s: %.2f s" % wall)
check(doc["headline"] == 178.8 and doc["areas"] == {"chat": 103.76, "delegation": 75.01},
      "calibration headline at R = 5 min: A 103.8 + B 75.0 = 178.8 OM/d: %s %s" % (doc["headline"], doc["areas"]))
check(doc["r_band"] == [83.5, 237.4] and doc["presence"] is False,
      "with no presence journal the R band is shown: R 2 min 83.5, R 10 min 237.4: %s" % doc["r_band"])
leaves = sum(v for area in doc["partition"].values() for v in area.values())
check(abs(leaves - doc["headline"]) < 0.1 and all(abs(sum(doc["partition"][a].values()) - v) < 0.05
                                                   for a, v in doc["areas"].items()),
      "the partition's leaves sum to their areas and to the headline: %.2f vs %.1f" % (leaves, doc["headline"]))
check(doc["head"] == "179 min/day · R 2/10: 84/237", "the headline: %s" % doc["head"])
backlog = [p for p in doc["problems"] if p["rule"] == "opportunity"]
check([p["id"] for p in backlog] == ["opportunity:chat/hooks", "opportunity:chat/tests"],
      "the backlog by score holds only equivalent levers; risk levers with no quality evidence are not shown: %s"
      % [p["id"] for p in backlog])
check(all(p["state"] == "watch" and set(p["opportunity"]) >= {"om_day", "saving", "confidence", "effort_h", "night_cost_h",
                                                                "score", "levers"}
          and p["opportunity"]["score"] == round(p["opportunity"]["saving"] * p["opportunity"]["confidence"]
                                                 / (p["opportunity"]["effort_h"] + p["opportunity"]["night_cost_h"]), 3)
          for p in backlog), "every opportunity stores its score fields and the score recomputes from them")
check(doc["selection"] == ["opportunity:chat/hooks"], "the night pick skips scores under SCORE_MIN: %s" % doc["selection"])
check({"cost", "yield"} <= set(doc) and set(doc["cost"]) == {"collector_cpu_min_day", "fixer_worker_min", "review_min",
                                                              "slot_queue_min", "landing_delay_min"}
      and set(doc["yield"]) == {"proven_om_day", "pending_om_day"}, "own keys cost and yield")
check([b["id"] for b in doc["blind_spots"]] == ["presence", "speed-days"],
      "missing presence and machine inputs are blind spots: %s" % doc["blind_spots"])
check(doc["partition"]["chat"]["model"] > 0 and not [p for p in doc["problems"] if p.get("component") == "chat/model"
                                                      or p["id"].startswith("opportunity:chat/model")],
      "model generation minutes are shown as a measured leaf and never carry a lever")

module_loader = importlib.machinery.SourceFileLoader("speed_doctor", os.path.join(root, "bin", "speed-doctor"))
module = importlib.util.module_from_spec(importlib.util.spec_from_loader("speed_doctor", module_loader))
module_loader.exec_module(module)
check(all(p["opportunity"]["quality"] == "equivalent" and module.OUTPUT_PROOF in p["opportunity"]["proof"]
          for p in backlog), "every ranked lever is equivalent and its proof demands output equivalence on the replay")
for bad in ({"component": "chat/x", "lever": "switch Opus to Sonnet", "quality": "equivalent"},
            {"component": "chat/x", "lever": "lower the effort for reviews", "quality": "equivalent"},
            {"component": "chat/x", "lever": "smaller thinking budget", "quality": "equivalent"},
            {"component": "delegation/workers", "lever": "a cheaper vendor for relays", "quality": "equivalent"},
            {"component": "chat/model", "lever": "shorter answers", "quality": "equivalent"},
            {"component": "chat/x", "lever": "cache the digest"}):
    try:
        module.validate_levers([bad])
        rejected = False
    except ValueError:
        rejected = True
    check(rejected, "a forbidden or unclassed lever is rejected: %s" % bad)
source = open(os.path.join(root, "bin", "speed-doctor")).read()
fed = source.replace("LEVERS = [\n", 'LEVERS = [\n    {"component": "chat/hooks", "lever": "downgrade Opus to Flash for hooks", "effort": "S",'
                     ' "confidence": "measured", "saving": 0.9, "night_cost_h": 0.0, "proof": "latency",'
                     ' "quality": "equivalent"},\n', 1)
check(fed != source, "the forbidden row is fed into LEVERS")
try:
    exec(compile(fed, os.path.join(root, "bin", "speed-doctor"), "exec"),
         {"__name__": "fed", "__file__": os.path.join(root, "bin", "speed-doctor")})
    loaded = True
except ValueError as exc:
    loaded = "forbidden lever class" not in str(exc)
check(not loaded, "bin/speed-doctor refuses to load with a model-downgrade LEVERS row")
risk = {"component": "chat/compaction", "lever": "compaction window", "effort": "S", "confidence": "measured",
        "saving": 0.9, "night_cost_h": 0.0, "proof": "tail", "quality": "risk"}
proven = dict(risk, quality_evidence={"compared": "10 sessions old vs new window", "data": "/tmp/x.jsonl",
                                      "result": "same decisions in 10/10"})
check(module.shown_levers([risk]) == [] and module.shown_levers([dict(proven, quality_evidence={"compared": "x"})]) == [],
      "a risk lever without complete quality evidence is not shown")
shown = module.shown_levers([proven])
fields = module.opportunity_fields(100.0, shown[0])
check(shown[0]["needs_egor"] is True and fields["quality_evidence"]["result"] == "same decisions in 10/10"
      and module.select([{"id": "opportunity:risk", "opportunity": fields}]) == []
      and module.select([{"id": "opportunity:risk", "opportunity": dict(fields, needs_egor=False)}]) == [],
      "a risk lever with evidence is a needs-Egor proposal and never enters the night pick, whatever its score")
check(module.select([{"id": "opportunity:eq", "opportunity": module.opportunity_fields(100.0, module.LEVERS[0])}])
      == ["opportunity:eq"], "an equivalent lever over SCORE_MIN enters the night pick")
row = lambda om, status, fix: {"id": "s-%s" % om, "status": status, "om_day": om, "match": {"rule": "opportunity"},
                               "fixes": [fix]}
check(module.speed_yield({"rows": [row(2, "fixed", {"equivalence": {"compared": "replay", "data": "d", "result": "same"}}),
                                   row(3, "fixed", {"at": "2026-10-03"}), row(5, "fixed-pending", {}),
                                   dict(row(7, "fixed", {"equivalence": {"compared": "r", "data": "d", "result": "s"}}),
                                        match={"rule": "wait"})]})
      == {"proven_om_day": 2.0, "pending_om_day": 8.0},
      "a fixed Speed row is proven only with its output-equivalence proof; one without it stays pending")
check(module.covers({"chat.om_per_100_prompts|all|-": {"days": 6}}) == []
      and module.covers({"chat.om_per_100_prompts|all|-": {"days": 7}})
      == [["wait", "*", "chat"], ["wait_cut", "*", "chat"], ["local_slow", "*", "chat"]],
      "Speed covers a component's Harness rules only once it is judged against a 7-day baseline")

menu, _ = speed("speed", "--menu")
lines = menu.stdout.splitlines()
check(lines[0] == "T\t0\t%d\tHarness doctor: OK" % HI and lines[1] == "0\t\t\tSpeed: ok · 179 min/day · R 2/10: 84/237"
      and "1\t\t\tChat turns: 104 min/day · model 64 · tools 30 · tests 5.4" in lines
      and "1\t\t\tDelegation: +75 min/day · workers 54 · background Bash 16 · media 2.7" in lines
      and "2\td\t\t1 · chat/hooks · saves <1 min/day · S · provable-absence fast path for the hook setting the Pre-Bash floor"
      in lines and "1\td\t\tNeeds Egor: nothing" in lines,
      "the Harness menu opens on the Speed line with the area lines and the ranked backlog under it: %s" % lines[:3])

presence = os.path.join(work, "speed-present", "presence")
os.makedirs(presence)
for day in ("2026-09-29", "2026-09-30", "2026-10-01", "2026-10-02"):
    start = int(h.day_start(day))
    with open(os.path.join(presence, day + ".tsv"), "w") as handle:
        handle.write("".join("%d\t5\tcom.mitchellh.ghostty\n" % m for m in range(start, start + 86400, 60)))
here, _ = speed("speed-present")
check(here["presence"] is True and here["r_band"] is None and here["headline"] == doc["r_band"][1]
      and here["head"].endswith("· presence"),
      "presence, always at the machine: every R = 10 min candidate minute counts and the R band goes: %s %s"
      % (here["headline"], here["head"]))
for path in glob.glob(os.path.join(presence, "*.tsv")):
    with open(path) as handle:
        text = handle.read().replace("\t5\t", "\t900\t")
    with open(path, "w") as handle:
        handle.write(text)
away, _ = speed("speed-present")
check(0 < away["headline"] < doc["headline"] and
      abs(sum(v for a in away["partition"].values() for v in a.values()) - away["headline"]) < 0.1,
      "presence, idle all along: only the last R before each reaction counts, still partitioned: %s" % away["headline"])

days = os.path.join(work, "speed-judged", "days")
os.makedirs(days)
key = "chat.om_per_100_prompts|all|-"
for offset in range(3, 17):
    day = h.local_day(LO - offset * 86400)
    with open(os.path.join(days, day + ".json"), "w") as handle:
        json.dump({"day": day, "values": {key: [10.0, 100]}}, handle)


def judged(second):
    for day, value in (("2026-09-30", 20.0), ("2026-10-01", second)):
        with open(os.path.join(days, day + ".json"), "w") as handle:
            json.dump({"day": day, "values": {key: [value, 100]}}, handle)
    return speed("speed-judged")[0]


red = judged(20.0)
regs = [p for p in red["problems"] if p["rule"] == "regression"]
check([(p["id"], p["state"]) for p in regs] == [("regression:" + key, "new")] and red["problem_count"] == 1
      and red["status"] == "problems" and red["baselines"][key]["median"] == 10.0
      and ["wait", "*", "chat"] in red["covers"],
      "a unit metric over 1.3 x its 28-day median on two consecutive days is a counted regression: %s" % regs)
calm = judged(12.0)
check(not [p for p in calm["problems"] if p["rule"] == "regression"] and calm["problem_count"] == 0,
      "one day over 1.3 x the baseline is no regression")

harness = {"status": "problems", "as_of_s": HI, "problem_count": 3, "blind_spots": [], "periods": {}, "extras": [],
           "title": "Harness doctor: 3 problems", "footer": "as of 21:50",
           "problems": [{"id": "wait:pre-bash", "rule": "wait", "ident": "pre-bash", "state": "new", "group": "Waits",
                         "fact": "a wait"},
                        {"id": "guards:x", "rule": "guard", "ident": "x", "state": "new", "group": "Guards",
                         "fact": "a guard"},
                        {"id": "load:memory", "rule": "load", "ident": "memory", "state": "open",
                         "group": "Memory guard", "fact": "a memory alarm"}],
           "sections": [h.section("Waits", [h.row(["a wait"], red=[0], say="a wait")], [""], [False]),
                        h.section("Guards", [h.row(["a guard"], red=[0], say="a guard")], [""], [False]),
                        h.section("Memory guard", [h.row(["a memory alarm"], red=[0], say="a memory alarm")], [""],
                                  [False])]}
merged = h.apply_speed(copy.deepcopy(harness), red)
wait = merged["problems"][0]
check((wait["state"], wait["was_state"], wait["judged_by"]) == ("watch", "new", "speed:chat")
      and merged["problem_count"] == 3 and merged["title"] == "Harness doctor: 3 problems"
      and [p["id"] for p in merged["problems"] if p.get("speed") and p["state"] in h.LOUD_STATES] == ["regression:" + key],
      "the wait rule Speed covers is judged once, by Speed: its verdict turns watch beside the counted regression")
check(counted_once(merged) and not counted_once(dict(merged, problems=harness["problems"] + [regs[0]], problem_count=4)),
      "no rule is counted twice in problem_count: the double-count check passes the merge and fails both verdicts")
again = h.apply_speed(copy.deepcopy(merged), red)
check(json.dumps(again, sort_keys=True) == json.dumps(merged, sort_keys=True),
      "laying the same section in again changes nothing")
bare = h.apply_speed(copy.deepcopy(merged), None)
check([p["state"] for p in bare["problems"]] == ["new", "new", "open"] and "speed" not in bare
      and not [p for p in bare["problems"] if "judged_by" in p] and bare["problem_count"] == 3,
      "without a section every rule gets its own verdict back")
lines = h.menu_text(merged).splitlines()
check(lines[1].startswith("0\t\tr:") and "Speed: 1 problem · 179 min/day" in lines[1]
      and lines.index("1\t\t\tWaits: watch · a wait") > 1 and any(l.startswith("0\t") and "Guards: 1 problem" in l
                                                                   for l in lines),
      "the Speed line heads the menu with its count, the Waits section under it, Guards after it: %s" % lines[1:3])

harness_dir = os.path.join(work, "harness")
with open(os.path.join(harness_dir, "latest.json"), "w") as handle:
    json.dump(harness, handle)
own = os.path.join(work, "speed-own")
journals = {"hs": "1\t2\tdoctors:bg\n", "merge-kick": "1\t5\t3\n", "presence": "%d\t5\t-\n" % (HI // 60)}
old, recent = h.local_day(HI - 36 * 86400), h.local_day(HI - 34 * 86400)
for sub, body in journals.items():
    os.makedirs(os.path.join(own, sub))
    for day in (old, recent):
        with open(os.path.join(own, sub, day + ".tsv"), "w") as handle:
            handle.write(body)
with open(os.path.join(harness_dir, "lock"), "w") as held:
    fcntl.flock(held, fcntl.LOCK_EX)
    out, _ = speed("speed-own", "--quiet")
    check(out.returncode == 0 and "speed" not in json.load(open(os.path.join(harness_dir, "latest.json"))),
          "a Harness run holding its lock is never written under: the merge skips")
check(all(not os.path.exists(os.path.join(own, sub, old + ".tsv"))
          and os.path.exists(os.path.join(own, sub, recent + ".tsv")) for sub in journals),
      "a persisting run prunes its hs, merge-kick and presence days past 35 days and keeps the rest")
with open(os.path.join(work, "doctors", "collector-runs.jsonl")) as handle:
    runs = [json.loads(l) for l in handle]
check([r["doctor"] for r in runs] == ["speed"] and set(runs[0]) == {"doctor", "start", "wall_s", "cpu_s", "trigger"},
      "a persisting run journals its collector row: %s" % runs)
out, _ = speed("speed-own", "--quiet")
latest = json.load(open(os.path.join(harness_dir, "latest.json")))
first = latest["speed"]
menu_txt = open(os.path.join(harness_dir, "menu.txt")).read().splitlines()
check(out.returncode == 0 and first["headline"] == doc["headline"] and counted_once(latest)
      and menu_txt[1] == "0\t\tr:7:9\tSpeed: 1 problem · 179 min/day · R 2/10: 84/237"
      and latest["problems"][0]["state"] == "new" and latest["problem_count"] == 3
      and not os.path.exists(os.path.join(own, "latest.json")) and not os.path.exists(os.path.join(own, "menu.txt")),
      "a persisting run lays its section into Harness's latest.json and the top of its menu.txt and writes neither "
      "file of its own; with no baseline the wait keeps its own verdict and counts under Speed: %s" % menu_txt[:2])

events_file = os.path.join(work, "harness", "events", "2026-10-02.jsonl")
with open(events_file) as handle:
    text = handle.read()
at = text.index('["t",', 100)
with open(events_file, "r+") as handle:
    handle.seek(at)
    handle.write('["x",')
Q = 1790920000.0
extra = ["t", Q, "zzzzzzzz", Q + 300, "h", [1, 1, 1], 0, [Q, Q + 350], [], {"gen": 300.0}, {}, []]
with open(events_file, "a") as handle:
    handle.write(json.dumps(extra) + "\n")
speed("speed-own", "--quiet")
second = json.load(open(os.path.join(harness_dir, "latest.json")))["speed"]
check(abs(second["headline"] - first["headline"] - 300 / 60.0 / second["window"]["days"]) < 0.06,
      "a second run reads only the appended bytes: the new turn adds its 5 minutes, the rewritten old row stays read: "
      "%s -> %s" % (first["headline"], second["headline"]))
cached = json.load(open(os.path.join(own, "state.json")))["events"]["2026-10-02"]["rows"]
folded = sum(1 for line in text.splitlines() if line[:5] in ('["t",', '["d",', '["s",')) + 1
check(len(cached) == folded, "the second run appends only the new row to its day cache: %d rows, %d expected"
      % (len(cached), folded))
check(module.score_of(2.0, 0.5, 1.0, 3.0) == 0.25, "a lever's night cost divides its score with the effort")
pick = [{"id": i, "opportunity": {"effort_h": e, "night_cost_h": 0.0, "needs_egor": False, "quality": "equivalent",
                                  "score": 1.0, "hooks": i == "c"}} for i, e in (("a", 1), ("b", 3), ("c", 1), ("d", 1))]
check(module.select(pick) == ["a", "b", "c", "d"]
      and module.select(pick, [{"component": "chat/tests"}]) == ["a", "c", "d"]
      and module.select(pick, [{"component": "machine/contention"}] * 3) == ["a"]
      and module.select(pick, [{"component": "chat"}]) == ["a", "b", "d"],
      "loud regressions go first: each takes its cheapest lever's hours, a K slot and that lever's hook turn")

repos = base["HARNESS_REPOS_DIR"]
shutil.copytree(os.path.join(root, "tests", "fixtures", "code-doctor", "corpus", "repos", "alpha"),
                os.path.join(repos, "alpha"))
os.makedirs(base["STATUSLINE_CACHE_DIR"])
with open(os.path.join(base["STATUSLINE_CACHE_DIR"], "test-history.jsonl"), "w") as handle:
    for secs in (300, 310, 290):
        handle.write(json.dumps({"end": HI - 3600, "secs": secs, "who": "chat", "repo": "alpha",
                                 "label": "test_isolation"}) + "\n")
        handle.write(json.dumps({"end": HI - 3600, "secs": 200, "who": "chat", "repo": "alpha", "label": "test_slow"}) + "\n")
        handle.write(json.dumps({"end": HI - 3600, "secs": 30, "who": "chat", "repo": "alpha", "label": "test_old_sync"}) + "\n")
hooks_repo = os.path.join(work, "hooks-repo")
os.makedirs(hooks_repo)
git = lambda *a, **env: subprocess.run(["git", "-C", hooks_repo] + list(a), check=True, capture_output=True,
                                       env=dict(os.environ, GIT_AUTHOR_NAME="t", GIT_AUTHOR_EMAIL="t@t",
                                                GIT_COMMITTER_NAME="t", GIT_COMMITTER_EMAIL="t@t", **env))
git("init", "-q")
for name in ("tuned", "busy", "fresh"):
    with open(os.path.join(hooks_repo, name + ".sh"), "w") as handle:
        handle.write("#!/bin/bash\necho %s\n" % name)
for names, ago in ((("tuned.sh", "busy.sh"), 6), (("fresh.sh",), 2)):
    git("add", *names)
    stamp = "%d +0000" % (HI - ago * 86400)
    git("commit", "-q", "-m", "hooks", GIT_AUTHOR_DATE=stamp, GIT_COMMITTER_DATE=stamp)
settings = os.path.join(work, "settings.json")
with open(settings, "w") as handle:
    json.dump({"hooks": {"PreToolUse": [{"matcher": "Bash", "hooks": [
        {"type": "command", "command": os.path.join(hooks_repo, n + ".sh")} for n in ("tuned", "busy", "fresh")]}]}}, handle)
speed_days = {}
for ago in (9, 8, 5, 4, 3, 1):
    tuned, busy = (900000, 0) if ago in (9, 8) else (0, 0) if ago == 1 else (1000, 900000)
    speed_days[h.local_day(HI - ago * 86400)] = {"hook_cpu_us": {"tuned.sh": [10, tuned * 1000], "busy.sh": [10, busy * 1000],
                                                                 "fresh.sh": [10, 900000 * 1000]}}
os.environ.update({k: v for k, v in base.items() if k not in ("HOME", "PATH")}, HARNESS_SETTINGS=settings)
moved = {p["id"]: p for p in module.moved_opportunities(lambda component: 10.0, speed_days, HI)}
check(sorted(moved) == ["opportunity:hooks/busy.sh", "opportunity:tests/alpha/test_isolation",
                        "opportunity:tests/alpha/test_slow"],
      "heavy suites (median >= 120 s) and hot hooks become Speed opportunities; a hook counts only days after its "
      "last commit and waits for 3 of them: %s" % sorted(moved))
iso, slow = moved["opportunity:tests/alpha/test_isolation"], moved["opportunity:tests/alpha/test_slow"]
check(iso["opportunity"]["protected"] == "protects isolation" and "protected" not in slow["opportunity"]
      and "protects isolation" in iso["fact"] and iso["opportunity"]["quality"] == "equivalent"
      and iso["opportunity"]["levers"] == ["speed up the suite and keep every check"] and iso["state"] == "watch",
      "a heavy suite whose head names isolation keeps it as `protected`; its lever speeds it up and keeps every check")
with open(base["CODE_LEDGER"], "w") as handle:
    json.dump({"keep": [{"path": "alpha/tests/test_slow.sh", "requirement": "kept for the lock race"}]}, handle)
moved = {p["id"]: p for p in module.moved_opportunities(lambda component: 10.0, {}, HI)}
check(moved["opportunity:tests/alpha/test_slow"]["opportunity"]["protected"] == "kept for the lock race",
      "a code-ledger keep row protects its suite with its requirement")

stub = os.path.join(work, "speed-stub")
with open(stub, "w") as handle:
    handle.write('#!/bin/sh\nprintf "%%s %%s\\n" "$DOCTOR_TRIGGER" "$*" > %s/exec.out\n' % work)
os.chmod(stub, 0o755)
probe = ("import importlib.machinery, importlib.util, sys\n"
         "l = importlib.machinery.SourceFileLoader('h', sys.argv[1])\n"
         "m = importlib.util.module_from_spec(importlib.util.spec_from_loader('h', l)); l.exec_module(m)\n"
         "m.exec_speed(); print('returned')\n")
env = dict(base, SPEED_DOCTOR_CMD=stub)
skipped = subprocess.run([sys.executable, "-c", probe, os.path.join(root, "bin", "harness-doctor")], env=env,
                         capture_output=True, text=True)
check(skipped.stdout.strip() == "returned" and not os.path.exists(os.path.join(work, "exec.out")),
      "a fixture Harness directory with no Speed directory of its own never runs Speed")
ran = subprocess.run([sys.executable, "-c", probe, os.path.join(root, "bin", "harness-doctor")],
                     env=dict(env, SPEED_DOCTOR_DIR=os.path.join(work, "speed-exec")), capture_output=True, text=True)
check(ran.stdout.strip() == "" and open(os.path.join(work, "exec.out")).read() == "harness --quiet\n",
      "Harness execs Speed after a successful run, tagged harness: %r" % ran.stdout)
print(count[0])
EOF
) || { printf 'FAIL: the Speed block misjudged the calibration fixture\n' >&2; exit 1; }

printf 'PASS: %s asserts; speed-doctor turns Harness'"'"'s owner turns and delegations into 178.8 OM/d with its R band, a partition that sums to it, a scored backlog of equivalent levers only (forbidden model/effort/thinking/vendor levers rejected at load, risk levers only as evidenced needs-Egor proposals, yield proven only with output equivalence), presence, two-day regressions, a merge into the Harness document and the top of its menu with each rule counted once, heavy-suite and hot-hook opportunities with their protections, offset reads, a 35-day journal prune and its exec from Harness\n' "$asserts"
