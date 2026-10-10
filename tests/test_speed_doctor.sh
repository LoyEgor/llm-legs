#!/usr/bin/env bash
. "${BASH_SOURCE%"${BASH_SOURCE##*/}"}lib/suite-journal.sh"
# bin/speed-doctor, the Speed block of the Harness doctor, over the 2026-09-29 .. 10-02 calibration transcripts folded
# by Harness's own C1 reader: the headline, the R band, a partition that sums to it, the backlog and its scores, the
# quality rule, presence, judging, the merge into Harness's document with each rule counted once, the moved heavy-test
# and hot-hook opportunities, the offset reads, the journal prune and Harness's exec. Fixture directories only.
set -u
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

asserts=$(python3 - "$ROOT" "$WORK" <<'EOF'
import copy, fcntl, gzip, glob, importlib.machinery, importlib.util, json, os, resource, shutil, subprocess, sys

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
projects = os.environ.pop("CLAUDE_PROJECTS_DIR")
os.environ.pop("HARNESS_DOCTOR_BOOTS")

ledger = os.path.join(work, "ledger.json")
with open(ledger, "w") as handle:
    json.dump({"owner": "Harness Doctor", "rows": [], "blind_spots": []}, handle)
base = {"HOME": os.path.join(work, "home"), "HARNESS_DOCTOR_DIR": os.path.join(work, "harness"),
        "DOCTORS_DIR": os.path.join(work, "doctors"), "WORKER_STATS_DIR": os.path.join(work, "worker-stats"),
        "CODE_DOCTOR_DIR": os.path.join(work, "code"), "HARNESS_LEDGER": ledger,
        "CODE_LEDGER": os.path.join(work, "code-ledger.json"), "STATUSLINE_CACHE_DIR": os.path.join(work, "sl"),
        "HARNESS_REPOS_DIR": os.path.join(work, "repos"), "RUN_SUITES_JOURNAL": os.path.join(work, "run-suites.jsonl"),
        "SPEED_DOCTOR_NOW": str(HI), "PATH": os.environ["PATH"]}


def speed(folder, *args, **env):
    """The output and the run's CPU seconds: the machine's load stretches its wall time, never its CPU."""
    before = resource.getrusage(resource.RUSAGE_CHILDREN)
    out = subprocess.run([os.path.join(root, "bin", "speed-doctor")] + list(args or ["--json"]),
                         env=dict(base, SPEED_DOCTOR_DIR=os.path.join(work, folder), **env),
                         capture_output=True, text=True)
    after = resource.getrusage(resource.RUSAGE_CHILDREN)
    cpu = after.ru_utime - before.ru_utime + after.ru_stime - before.ru_stime
    if "--json" in (args or ["--json"]):
        return json.loads(out.stdout), cpu
    return out, cpu


def counted_once(document):
    """Each (rule, ident) is loud at most once, and no rule Speed covers is loud beside it."""
    loud = [(p["rule"], p.get("ident")) for p in document["problems"] if p["state"] in h.LOUD_STATES]
    covered = {(rule, ident) for rule, ident, _ in (document.get("speed") or {}).get("covers") or ()}
    return (len(loud) == len(set(loud)) == document["problem_count"]
            and not [k for k in loud if k in covered or (k[0], "*") in covered])


doc, cpu = speed("speed")
check(doc["status"] == "ok" and doc["problem_count"] == 0 and not {"contract", "doctor", "title"} & set(doc),
      "the calibration section has nothing counted and no document keys of its own: %s" % doc["status"])
check(cpu <= 2.0, "speed-doctor reads its inputs in <= 2 CPU s: %.2f s" % cpu)
check(doc["headline"] == 179.3 and doc["areas"] == {"chat": 103.42, "delegation": 75.91},
      "calibration headline at R = 5 min: A 103.4 + B 75.9 = 179.3 OM/d: %s %s" % (doc["headline"], doc["areas"]))
check(doc["r_band"] == [87.9, 237.9] and doc["presence"] is False,
      "with no presence journal the R band is shown: R 2 min 87.9, R 10 min 237.9: %s" % doc["r_band"])
leaves = sum(v for area in doc["partition"].values() for v in area.values())
check(abs(leaves - doc["headline"]) < 0.1 and all(abs(sum(doc["partition"][a].values()) - v) < 0.05
                                                   for a, v in doc["areas"].items()),
      "the partition's leaves sum to their areas and to the headline: %.2f vs %.1f" % (leaves, doc["headline"]))
backlog = [p for p in doc["problems"] if p["rule"] == "opportunity"]
check(doc["head"] == "3.3 min/day over the floor · 179 OM/d · 3.9 of 7 days covered · R 2/10: 88/238"
      and doc["lost_min_day"] == doc["budget"]["lost_min_day"] == 3.3, "the headline: %s" % doc["head"])
check([(p["id"], p["opportunity"]["recoverable_min_day"]) for p in backlog]
      == [("opportunity:chat/tools", 9.01), ("opportunity:delegation/background Bash", 5.07),
          ("opportunity:chat/hooks", 3.3), ("opportunity:chat/tests", 0.91), ("opportunity:delegation/reviews", 0.65)],
      "the backlog by recoverable min/day holds only equivalent levers; risk levers with no quality evidence are not "
      "shown; a slice no lever names ranks on the generic slice lever; a class over its floor adds its gap to the "
      "opportunity already pricing it: %s"
      % [(p["id"], p["opportunity"]["recoverable_min_day"]) for p in backlog])
check(all(p["state"] == "watch" and set(p["opportunity"]) >= {"om_day", "saving", "confidence", "effort_h", "night_cost_h",
                                                                "score", "levers"}
          and p["opportunity"]["score"] == round(p["opportunity"]["recoverable_min_day"] * p["opportunity"]["confidence"]
                                                 / (p["opportunity"]["effort_h"] + p["opportunity"]["night_cost_h"]), 3)
          for p in backlog), "every opportunity stores its score fields and the score recomputes from them")
check(doc["selection"] == ["opportunity:chat/tools", "opportunity:delegation/background Bash"],
      "the night takes the biggest recoverable gap first: %s" % doc["selection"])
check({"cost", "yield"} <= set(doc) and set(doc["cost"]) == {"collector_cpu_min_day"}
      and set(doc["yield"]) == {"proven_om_day", "pending_om_day"}, "own keys cost and yield")
check([b["id"] for b in doc["blind_spots"]] == ["presence", "speed-days"],
      "missing presence and machine inputs are blind spots: %s" % doc["blind_spots"])
check(doc["partition"]["chat"]["model"] > 0 and not [p for p in doc["problems"] if p.get("component") == "chat/model"
                                                      or p["id"].startswith("opportunity:chat/model")],
      "model generation minutes are shown as a measured leaf and never carry a lever")

module_loader = importlib.machinery.SourceFileLoader("speed_doctor", os.path.join(root, "bin", "speed-doctor"))
module = importlib.util.module_from_spec(importlib.util.spec_from_loader("speed_doctor", module_loader))
module_loader.exec_module(module)
check([module.delegation_leaf(w) for w in ("Bash:worker", "Bash:review", "Agent:codex-worker", "Agent:review-waiter", "Bash")]
      == ["workers", "reviews", "workers", "reviews", "background Bash"],
      "a chat's own background worker-run / review-bench wait is a worker / review delegation, as the relays were")
check(doc["coverage"] == {"days": 3.91, "window_days": 7, "backfill_files_done": 0, "backfill_files": 0}
      and doc["why_none"] is None and all(0 < p["opportunity"]["data_confidence"] <= round(4 / 7.0, 2) for p in backlog)
      and [module.seen_need("seen_days", d) for d in (7, 3.91, 1)] == [3, 2, 1],
      "3.9 covered days still select, with a lower data confidence and the seen filters scaled to them: %s"
      % [p["opportunity"].get("data_confidence") for p in backlog])
early_dir = os.path.join(work, "harness-early")
shutil.copytree(os.path.join(work, "harness"), early_dir)
with open(os.path.join(early_dir, "events", h.local_day(HI - 6 * 86400) + ".jsonl"), "w") as handle:
    handle.write(json.dumps(["w", HI - 6 * 86400, "x"]) + "\n")
early, _ = speed("speed-early", HARNESS_DOCTOR_DIR=early_dir)
check(early["window"] == doc["window"] and early["headline"] == doc["headline"],
      "an events file from before Harness's turn rows began never widens the window: %s" % early["window"])
lever_repo = os.path.join(base["HARNESS_REPOS_DIR"], "lever-hooks")
os.makedirs(lever_repo)
lever_hook = os.path.join(lever_repo, "review-flow-gate.sh")
lever_settings = os.path.join(work, "lever-settings.json")
with open(lever_settings, "w") as handle:
    json.dump({"hooks": {"PreToolUse": [{"matcher": "Bash", "hooks": [{"type": "command", "command": lever_hook}]}]}}, handle)


def lever_git(ago, *args):
    stamp = "%d +0000" % (HI - ago * 86400)
    return subprocess.run(["git", "-C", lever_repo] + list(args), check=True, capture_output=True, text=True,
                          env=dict(os.environ, GIT_AUTHOR_NAME="t", GIT_AUTHOR_EMAIL="t@t", GIT_COMMITTER_NAME="t",
                                   GIT_COMMITTER_EMAIL="t@t", GIT_AUTHOR_DATE=stamp, GIT_COMMITTER_DATE=stamp)).stdout.strip()


def lever_commit(ago, text):
    with open(lever_hook, "a") as handle:
        handle.write(text + "\n")
    lever_git(ago, "add", "-A")
    lever_git(ago, "commit", "-q", "-m", text)


lever_git(6, "init", "-q")
check(subprocess.run(["git", "-C", lever_repo, "config", "core.hooksPath"], capture_output=True).returncode == 1,
      "fixture commits, checkouts and merges run no global git hooks")
lever_commit(6, "#!/bin/bash")
lever_git(6, "checkout", "-q", "-b", "lever-fix")
lever_commit(6, "# the lever's fix")
lever_fix = lever_git(6, "rev-parse", "HEAD")
lever_git(6, "checkout", "-q", "-")
lever_git(2, "merge", "-q", "--no-ff", "-m", "land the lever's fix", "lever-fix")
lever_commit(1.5, "# unrelated")
base_om = [p["opportunity"]["om_day"] for p in backlog if p["id"] == "opportunity:chat/hooks"]
lever_doc, _ = speed("speed-lever-unfixed", HARNESS_SETTINGS=lever_settings)
check([p["opportunity"]["om_day"] for p in lever_doc["problems"] if p["id"] == "opportunity:chat/hooks"] == base_om,
      "a lever with no landed fix in its ledger row is charged the whole window, whatever its hook's later commits")
lever_ledger = os.path.join(work, "lever-ledger.json")
with open(lever_ledger, "w") as handle:
    json.dump({"owner": "Harness Doctor", "blind_spots": [], "rows": [
        {"id": "lever", "match": {"rule": "opportunity", "ident": "chat/hooks"}, "status": "fixed",
         "fixes": [{"in": "lever-hooks@" + lever_fix, "regressed_at": None}]}]}, handle)
saved_env, captured = dict(os.environ), []
os.environ.update({k: v for k, v in base.items() if k != "PATH"}, HARNESS_SETTINGS=lever_settings,
                  HARNESS_LEDGER=lever_ledger, SPEED_DOCTOR_DIR=os.path.join(work, "speed-lever-fixed"))
partition = module.partition
module.partition = lambda *a: captured.append((a, partition(*a))) or captured[-1][1]
lever_doc = module.collect(False, HI)
module.partition = partition
os.environ.clear()
os.environ.update(saved_env)
(_, _, lever_lo, _), (lever_credit, _) = captured[0]
landed = h.local_day(HI - 2 * 86400)
lever_secs = sum(s for (day, a, l), s in lever_credit.items() if (a, l) == ("chat", "hooks") and day > landed)
lever_om = [p["opportunity"]["om_day"] for p in lever_doc["problems"] if p["id"] == "opportunity:chat/hooks"]
check(lever_om and lever_om != base_om and lever_doc["headline"] == doc["headline"]
      and abs(lever_om[0] - lever_secs / 60.0 / ((HI - max(lever_lo, h.day_end(landed))) / 86400.0)) < 0.01,
      "a lever is charged per day only after its own fix landed through the merge that brought it in: %s" % lever_om)
loaded = {h.local_day(HI - back * 86400): {"machine": {"band_s": {"<1": 50000, "busy": 30000},
                                                       "probe_ms": {"<1": [10, 100, 10, 10, 0, 0, []],
                                                                    "busy": [10, 400, 40, 40, 0, 0, []]}}}
          for back in range(4)}
contention_since = h.local_day(HI - 2 * 86400)
stubs = (module.speed_days, module.lever_since, module.partition)
captured = []
module.speed_days = lambda lo, now: copy.deepcopy(loaded)
module.lever_since = lambda ledger, component: contention_since if component == "machine/contention" else None
module.partition = lambda *a: captured.append((a, partition(*a))) or captured[-1][1]
os.environ.update({k: v for k, v in base.items() if k != "PATH"}, SPEED_DOCTOR_DIR=os.path.join(work, "speed-contention"))
contention_doc = module.collect(False, HI)
module.speed_days, module.lever_since, module.partition = stubs
os.environ.clear()
os.environ.update(saved_env)
(_, _, c_lo, _), (c_credit, _) = captured[0]
c_span = (HI - max(c_lo, h.day_end(contention_since))) / 86400.0
c_local = sum(s for (d, a, l), s in c_credit.items() if a == "chat" and l in module.LOCAL_LEAVES and d > contention_since)
c_expected = module.machine_view({d: v for d, v in loaded.items() if d > contention_since}, c_local / 60.0 / c_span)["p_om_day"]
c_om = [p["opportunity"]["om_day"] for p in contention_doc["problems"] if p["id"] == "opportunity:machine/contention"]
check(c_expected and c_om and abs(c_om[0] - c_expected) < 0.01,
      "a landed machine/contention fix reprices it from the machine days after the fix, never drops it: %s vs %s"
      % (c_om, c_expected))
spike, pattern = ({"id": i, "opportunity": {"needs_egor": False, "score": 0.5, "data_confidence": c}}
                  for i, c in (("a-spike", round(1 / 7.0, 2)), ("b-pattern", round(4 / 7.0, 2))))
check([o["id"] for o in sorted([spike, pattern], key=module.rank_key)] == ["b-pattern", "a-spike"],
      "a pattern seen on several days ranks above a one-day spike of the same score")
low = {"id": "low", "opportunity": {"needs_egor": False, "quality": "equivalent", "score": 0.1, "effort_h": 1.0,
                                    "night_cost_h": 0.0, "hooks": False, "recoverable_min_day": 5.0}}
zero = {}
check(module.select([low]) == ["low"] and module.select([dict(low, opportunity=dict(low["opportunity"], score=0.0))], zero) == []
      and module.why_skipped(zero) == "1 score 0", "the night pick has no score floor: any positive score enters it")
below = dict(low, id="below", opportunity=dict(low["opportunity"], recoverable_min_day=4.99))
unpriced = dict(low, id="unpriced", opportunity={k: v for k, v in low["opportunity"].items() if k != "recoverable_min_day"})
repair = dict(low, id="repair", **{"class": "measurement fix"})
needed = dict(repair, id="needed", blind_for=["low"])
small = dict(repair, id="small", blind_for=["below"])
why = {}
check(module.select([below, low, unpriced, repair, needed, small], why) == ["low", "needed"],
      "5 min/day is inclusive; smaller, unpriced and pure measurement fixes stay out; only a named big blind opportunity admits repair")
check(module.why_skipped(why) == "2 expected gain <5 min/day or unpriced, 2 measurement fixes without a >=5 min/day blind opportunity",
      "all skipped opportunities have visible reasons even when another is selected")
check(module.time_budget.night_speed_skip({"rule": "time_floor", "unit": "min/day", "value": 31}) is None
      and module.time_budget.FLOOR_ROW_MIN_DAY == 30,
      "floor alarms keep their 30-minute detection threshold independently of night admission")

scored = [{"id": "opportunity:%s" % i, "opportunity": dict(low["opportunity"], score=s, effort_h=e, hooks=i.startswith("hook"))}
          for i, s, e in (("time/workers-active", 236.0, 3.0), ("chat/tests", 72.0, 1.0), ("hook", 36.0, 1.0),
                          ("hook2", 20.0, 1.0), ("cheap", 0.16, 1.0), ("over", 0.1, 1.0))]
check(module.select(scored) == [o["id"] for o in scored],
      "every hook lever enters the pick, in rank order: bin/doctor-fix sizes the night's hook share from free worker "
      "slots, never a fixed one a night")
six = [{"id": "opportunity:six%d" % i, "opportunity": dict(low["opportunity"], score=6.0 - i, effort_h=3.0)} for i in range(6)]
check(module.select(six) == [o["id"] for o in six],
      "six qualifying 3-hour levers are all selected, in score order: the worker slots' admission decides how many run "
      "at once, not a count or an hour budget")
gaps = {"lost_min_day": 95.3, "lines": ["Without the harness ≈ 40 % faster"],
        "floors": [{"class": "slot", "label": "worker slot queue", "floor_min_day": "slots lent during suites",
                    "actual_min_day": 300.0, "recoverable_min_day": 50.0, "chat_min_day": 0.0, "worker_min_day": 50.0},
                   {"class": "suite_run", "label": "suites running", "floor_min_day": "uncontended p10 wall",
                    "actual_min_day": 100.0, "recoverable_min_day": 40.0, "chat_min_day": 10.0, "worker_min_day": 30.0},
                   {"class": "locks", "label": "locks and polls", "floor_min_day": 0, "actual_min_day": 0.3,
                    "recoverable_min_day": 0.3, "chat_min_day": 0.3, "worker_min_day": 0.0},
                   {"class": "stop", "label": "stop hooks", "floor_min_day": 0, "actual_min_day": 5.0,
                    "recoverable_min_day": 5.0, "chat_min_day": 5.0, "worker_min_day": 0.0}],
        "workers_active": {"share": 0.1, "floor_share": 0.05, "recoverable_min_day": 80.0,
                           "parts": {"slot": 50.0, "suite_run": 30.0}},
        "last_night": {"id": "N9", "wall_s": 36000, "model_s": 3600, "share": 0.1, "floor_share": 0.15}}
timed = module.with_time(copy.deepcopy(backlog), gaps)
check(all("workers-active" not in o["id"] for o in timed)
      and [module.per_day(o["opportunity"]["recoverable_min_day"], o["opportunity"].get("worker_min_day", 0.0))
           for o in timed[:2]] == ["50 w-min/day", "10 min + 30 w-min/day"],
      "workers active is the parent of the worker classes and never ranks beside them; a gap's worker-minutes carry "
      "their own unit: %s" % [(o["id"], o["opportunity"].get("worker_min_day")) for o in timed])
check([(o["id"], o["opportunity"]["recoverable_min_day"]) for o in timed]
      == [("opportunity:time/slot", 50.0), ("opportunity:chat/tests", 40.0), ("opportunity:chat/tools", 9.01),
          ("opportunity:chat/hooks", 8.3), ("opportunity:delegation/background Bash", 5.07),
          ("opportunity:delegation/reviews", 0.65)]
      and module.select(timed) == [o["id"] for o in timed if o["opportunity"]["recoverable_min_day"] >= 5]
      and all(o["opportunity"]["score"] == module.score_of(o["opportunity"]["recoverable_min_day"], o["opportunity"]["confidence"],
                                                           o["opportunity"]["effort_h"], 0.0) for o in timed),
      "a class over its floor ranks by recoverable min/day: its own time opportunity, or its gap added to the "
      "opportunity already pricing it; under the worth line it is no opportunity; the night takes them all, biggest first: %s"
      % [(o["id"], o["opportunity"]["recoverable_min_day"]) for o in timed])
stop = gaps["floors"][-1]
own = module.with_time([], {"floors": [dict(stop, label="hooks", recoverable_min_day=20.0, worker_min_day=4.0,
                                            **{"class": "hooks"}), dict(stop, recoverable_min_day=10.0)]})
check([(o["id"], o["opportunity"]["recoverable_min_day"], o["opportunity"]["worker_min_day"]) for o in own]
      == [("opportunity:time/hooks", 30.0, 4.0)],
      "with no hook opportunity the Stop gap adds to the hooks time row, never the larger of the two: %s"
      % [(o["id"], o["opportunity"]) for o in own])
rows = module.floor_rows(gaps, {"rows": [{"id": "L1", "match": {"rule": "time_floor", "ident": "slot"}, "status": "fixed"}]}, HI)
held = [module.floor_rows(gaps, {"rows": [{"id": "L1", "match": {"rule": "time_floor", "ident": "slot"}, "status": "fixed",
                                           "fixes": [{"at": h.iso_time(HI - back * 3600), "files": [], "in": None}]}]},
                          HI)[0]["state"] for back in (20, 25)]
check(held == ["fixed-pending", "regressed"],
      "a fixed row over its floor regresses only once its 24 h window starts after the fix held: %s" % held)
pending_held = [module.floor_rows(gaps, {"rows": [{"id": "L1", "match": {"rule": "time_floor", "ident": "slot"},
                                                   "status": "fixed-pending",
                                                   "fixes": [{"at": h.iso_time(HI - back * 3600), "files": [], "in": None}]}]},
                                  HI)[0]["state"] for back in (20, 25)]
check(pending_held == ["fixed-pending", "regressed"],
      "a fixed-pending row over its floor regresses too once its 24 h window starts after the fix held: %s" % pending_held)
check([(r["id"], r["state"], r["value"], r["limit"]) for r in rows]
      == [("L1", "open", 50.0, 30), ("time_floor:suite_run", "new", 40.0, 30),
          ("time_floor:workers-active", "new", 0.1, 0.15)]
      and rows[1]["fact"] == "suites running 10 min + 30 w-min/day over its floor of uncontended p10 wall · proof: back "
      "under it"
      and rows[2]["fact"] == "workers were model-active 10 % of their wall on night N9 (floor 15 %) · proof: back under it"
      and module.floor_rows(dict(gaps, floors=gaps["floors"][2:], last_night=dict(gaps["last_night"], share=0.3)), {}, HI) == [],
      "a class more than 30 min/day over its floor and a night under the floor share its own parts derive (never the "
      "last day's workers') are named rows through the ledger's states; back under them there is no row: %s" % [(r["id"], r["state"]) for r in rows])
near = dict(gaps["last_night"], model_s=5300, share=0.147)
check(module.floor_rows(dict(gaps, floors=[], last_night=near), {}, HI) == []
      and [r["ident"] for r in module.floor_rows(dict(gaps, floors=[], last_night=dict(near, model_s=4000, share=0.111)),
                                                {}, HI)] == ["workers-active"],
      "the night row needs more than 30 minutes of the night's wall under the derived floor share, not a share point")
dead = {"class": "dead", "label": "dead worker runs", "floor_min_day": 0, "actual_min_day": 40.0,
        "recoverable_min_day": 40.0, "chat_min_day": 0.0, "worker_min_day": 40.0}
busy = dict(dead, label="suite slot wait", floor_min_day="waits on a busy machine", actual_min_day=300.0,
            **{"class": "suite_wait"})
check(set(module.time_budget.FLOORS) <= set(module.TIME_LEVERS),
      "every floored time class has its lever, or a gap over the worth line ends the Speed collector in KeyError: %s"
      % sorted(set(module.time_budget.FLOORS) - set(module.TIME_LEVERS)))
dead_time = module.with_time([], {"floors": [dead]})
dead_rows = module.floor_rows({"floors": [dead, busy]}, {}, HI)
check([(o["id"], o["opportunity"]["recoverable_min_day"], o["opportunity"]["levers"][0]) for o in dead_time]
      == [("opportunity:time/dead", 40.0, module.TIME_LEVERS["dead"]["lever"])]
      and [(r["id"], r["fact"], r["expected_min_day"]) for r in dead_rows]
      == [("time_floor:dead", "dead worker runs 40 w-min/day over its floor of 0.0 min/day · proof: back under it", 40.0),
          ("time_floor:suite_wait", "suite slot wait 40 w-min/day over its floor of waits on a busy machine · proof: "
           "back under it", 40.0)]
      and module.time_budget.improvement_class("time_floor", "time_floor:dead") == "dead",
      "dead worker runs are a Lost time class like the others: their own time opportunity with a lever, a floor row "
      "priced for the night's admission, and a queue's floor names the busy machine: %s %s"
      % ([(o["id"], o["opportunity"]) for o in dead_time], [(r["id"], r["fact"]) for r in dead_rows]))
try:
    every_time = module.with_time([], {"floors": [dict(dead, label=module.time_budget.LABEL[k], **{"class": k})
                                                  for k in module.time_budget.FLOORS]})
    every_unit = module.unit_rows({"refusal_cost": {"by_gate_min_day": {"gate-x": 40.0}}}, set())
except KeyError as exc:
    every_time, every_unit = [], exc
check({o["id"] for o in every_time} >= {"opportunity:time/" + k for k in module.time_budget.FLOORS if k != "stop"}
      and [o["id"] for o in every_unit] == ["opportunity:refusal/gate-x"],
      "every Lost time class with a floor and every gate's refusal row has its lever, so a new class never ends the "
      "Speed collector (exec'd by com.egor.harness-doctor) in KeyError: %r" % (every_unit,))
runs_journal = os.path.join(work, "full-runs.jsonl")
with open(runs_journal, "w") as handle:
    for session, scope, end, minutes in (("chatAAAAxyz", "full", HI - 600, 25), ("chatAAAAxyz", "all", HI - 60, 15),
                                         (None, "full", HI - 300, 60), ("chatBBBBxyz", "changed", HI - 300, 50),
                                         ("chatBBBBxyz", "full", HI - 90000, 50)):
        handle.write(json.dumps({"kind": "suites", "scope": scope, "session": session, "worker_run": None,
                                 "started_at": end - 60 * minutes, "ended_at": end}) + "\n")
    handle.write("{torn\n")
saved_runs_dir = os.environ.get("WORKER_RUN_DIR")
os.environ["WORKER_RUN_DIR"] = os.path.join(work, "no-worker-runs")
full = module.full_runs(HI, runs_journal)
os.environ.pop("WORKER_RUN_DIR")
if saved_runs_dir is not None:
    os.environ["WORKER_RUN_DIR"] = saved_runs_dir
full_rows = module.floor_rows({}, {}, HI, full)
check(full == {"min_day": 40.0, "chats": [("chatAAAA", 2)]}
      and [(r["id"], r["value"], r["limit"], r["fact"]) for r in full_rows]
      == [("time_floor:full-runs", 40.0, 30, "every-suite runs outside the night 40 min/day over its floor of none "
           "(chatAAAA ×2) · proof: back under it")]
      and module.floor_rows({}, {}, HI, dict(full, min_day=30.0)) == [],
      "every-suite runs a chat started in the last day are a floor row past 30 min/day, named by chat; the night's "
      "unsessioned run, a --changed run and an older run are not: %s %s" % (full, [r["fact"] for r in full_rows]))
parts = json.loads(next(l for l in h.menu_text({
    "problem_count": 0, "as_of_s": HI, "title": "t", "status": "error", "problems": [], "sections": [], "footer": "f",
    "speed": {"status": "ok", "budget": gaps}}).splitlines() if l.startswith("H\t"))[2:])["speed"]["issues"]
check(parts == [[50.0, "worker slot queue", "w-min/day"], [40.0, "tests", "min/day"], [5.0, "stop hooks", "min/day"]],
      "the menu header's floor gaps are chats' and workers' parts apart, each with its unit; suites running and "
      "their slot wait are one tests row, chats and workers summed: %s" % parts)
dead_parts = json.loads(next(l for l in h.menu_text({
    "problem_count": 0, "as_of_s": HI, "title": "t", "status": "error", "problems": [], "sections": [], "footer": "f",
    "speed": {"status": "ok", "budget": {"floors": [dead, gaps["floors"][-1]]}}}).splitlines()
    if l.startswith("H\t"))[2:])["speed"]["issues"]
check(dead_parts == [[40.0, "dead worker runs", "w-min/day"], [5.0, "stop hooks", "min/day"]],
      "dead worker runs reach the Lost time layer as a floor row in worker-minutes: %s" % dead_parts)
tests_header = json.loads(next(l for l in h.menu_text({
    "problem_count": 0, "as_of_s": HI, "title": "t", "status": "error", "problems": [], "sections": [], "footer": "f",
    "speed": {"status": "ok", "budget": gaps, "tests": {
        "regressions": [{"label": "suites per targeted run", "min_day": 1032.8}, {"label": "red runs", "min_day": 0}],
        "heavy": [{"label": "test_%d" % i, "min_day": 100.0 - i} for i in range(10)]}}}).splitlines()
    if l.startswith("H\t"))[2:])["speed"]["tests"]
check(tests_header == {"over": [[1032.8, "suites per targeted run"]],
                       "heavy": [[100.0 - i, "test_%d" % i] for i in range(8)]},
      "the menu header carries the tests row's lines: what grew over its usual, then the 8 heaviest suites: %s" % tests_header)
saved_env, saved = dict(os.environ), (module.with_time, module.time_budget.section)
os.environ.update({k: v for k, v in base.items() if k != "PATH"}, SPEED_DOCTOR_DIR=os.path.join(work, "speed-floor"))
module.with_time = lambda opportunities, budget: [dict(o, opportunity=dict(o["opportunity"], quality="risk"))
                                                  for o in saved[0](opportunities, budget)]
module.time_budget.section = lambda now, write: copy.deepcopy(gaps)
floored = module.collect(False, HI)
module.with_time, module.time_budget.section = saved
os.environ.clear()
os.environ.update(saved_env)
check(floored["selection"] == [] and floored["why_none"].startswith("110 min/day recoverable, but 6 are not output-equivalent")
      and floored["head"].startswith("15 min + 80 w-min/day over the floor · ") and floored["problem_count"] == 3
      and [l[3] for l in floored["menu"] if l[2]] == [r["fact"] for r in floored["problems"] if r["rule"] == "time_floor"]
      and [0, "", False, "Without the harness ≈ 40 % faster"] in floored["menu"],
      "an empty pick while minutes are recoverable names them; the floor rows count and show red in the menu beside "
      "the time block: %s · %s" % (floored["why_none"], floored["head"]))
refused = dict(copy.deepcopy(gaps), floors=gaps["floors"][2:3] + [
    {"class": "refusal", "label": "gate refusal recovery", "floor_min_day": 0, "actual_min_day": 12.0,
     "recoverable_min_day": 12.0, "chat_min_day": 8.0, "worker_min_day": 4.0},
    {"class": "hooks", "label": "hooks", "floor_min_day": 0, "actual_min_day": 40.0,
     "recoverable_min_day": 40.0, "chat_min_day": 40.0, "worker_min_day": 0.0}],
    refusal_cost={"by_gate_min_day": {"review-flow-gate.sh": 9.0, "write": 0.4}},
    hooks_by_hook_min_day={"hooks/cd-guard.sh": 18.5, "stop/stop-dispatch.sh": 6.0, "hooks/quick.sh": 0.1})
saved_env, saved = dict(os.environ), module.time_budget.section
os.environ.update({k: v for k, v in base.items() if k != "PATH"}, SPEED_DOCTOR_DIR=os.path.join(work, "speed-refusal"))
module.time_budget.section = lambda now, write: copy.deepcopy(refused)
gated = module.collect(False, HI)
module.time_budget.section = saved
os.environ.clear()
os.environ.update(saved_env)
rows = {p["id"]: p for p in gated["problems"] if p["id"].startswith("opportunity:")}
check(gated.get("status") != "error" and rows["opportunity:refusal/review-flow-gate.sh"]["opportunity"]["recoverable_min_day"] == 9.0
      and rows["opportunity:refusal/review-flow-gate.sh"]["opportunity"]["hook"] == "review-flow-gate.sh"
      and rows["opportunity:time/refusal"]["opportunity"]["recoverable_min_day"] == 3.0
      and rows["opportunity:time/refusal"]["opportunity"]["worker_min_day"] == 1.0
      and rows["opportunity:hooks/cd-guard.sh"]["opportunity"]["recoverable_min_day"] == 18.5
      and rows["opportunity:stop/stop-dispatch.sh"]["opportunity"]["target"] == "stop/stop-dispatch.sh"
      and "opportunity:refusal/write" not in rows and "opportunity:hooks/quick.sh" not in rows
      and module.time_budget.improvement_class("opportunity", "opportunity:stop/stop-dispatch.sh") == "stop"
      and "opportunity:refusal/review-flow-gate.sh" in gated["selection"],
      "a refusal gap over the worth line ranks through the collector; each gate and hook over it is its own row at "
      "its own minutes, and only the rest of its class stays a time row: %s" % sorted(
          (k, v["opportunity"]["recoverable_min_day"]) for k, v in rows.items() if "time/" in k or "/" in k[12:]))
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
      == ["opportunity:eq"], "an equivalent lever enters the night pick")
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
skipped_lines = [line for line in lines if "Night skipped:" in line]
check(doc["night_skipped"] in menu.stdout, "JSON and menu expose the same single skipped-jobs line")
check(len(skipped_lines) == 1 and all(name in skipped_lines[0] for name in
      ("opportunity:chat/hooks", "opportunity:chat/tests", "opportunity:delegation/reviews"))
      and "opportunity:chat/tools" not in skipped_lines[0],
      "one output line names the skipped small jobs while the qualifying jobs remain selected")
check(lines[0] == "T\t0\t%d\tHarness doctor: ok" % HI and lines[2] == "0\t\t\tLost time: ok · 3.3 min/day over the floor · 179 OM/d · 3.9 of 7 days covered · R 2/10: 88/238"
      and "1\t\t\tChat turns: 103 min/day · model 64 · tools 30 · tests 5.4" in lines
      and "1\t\t\tDelegation: +76 min/day · workers 54 · background Bash 17 · media 2.7" in lines
      and "2\td\t\t3 · chat/hooks · saves 3.3 min/day · S · provable-absence fast path for the hook setting the Pre-Bash floor"
      in lines and "1\td\t\tNeeds Egor: nothing" in lines,
      "the Harness menu opens on the Speed line with the area lines and the ranked backlog under it: %s" % lines[:3])
check([l["component"] for l in module.slice_levers({"background": {"hs lag": 18.0}, "delegation": {
          "workers": 26.0, "background Bash": 9.0}, "chat": {"model": 50.0, "residual": 1.0, "tools": 3.0, "hooks": 2.0}})]
      == ["chat/tools", "delegation/background Bash"],
      "a partition slice no lever names gets the generic slice lever; a named, forbidden or residual slice does not")
os.makedirs(os.path.join(work, "speed-hs", "hs"))
for back in (1, 2, 3):
    with open(os.path.join(work, "speed-hs", "hs", h.local_day(HI - back * 86400) + ".tsv"), "w") as handle:
        handle.write("%d\t%d\ths-lag\n" % ((HI - back * 86400) * 1e6, (HI - back * 86400 + 900) * 1e6))
lagged, _ = speed("speed-hs")
check("opportunity:background/hs lag" in lagged["selection"],
      "Hammerspoon main-thread lag is a Speed slice the night can select: %s" % lagged["selection"])

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
with open(os.path.join(presence, "2026-10-02.tsv")) as handle:
    one_day = handle.read()
for path in glob.glob(os.path.join(presence, "*.tsv")):
    os.unlink(path)
with open(os.path.join(presence, "2026-10-02.tsv"), "w") as handle:
    handle.write(one_day)
part, _ = speed("speed-present")
check(away["headline"] < part["headline"] < doc["headline"] and part["r_band"] is not None
      and "R 2/10" in part["head"],
      "presence logged on one day only: the other days keep the R = 5 min proxy, unknown is never away: %s %s"
      % (part["headline"], part["r_band"]))

transcripts = {"CLAUDE_PROJECTS_DIR": projects,"HARNESS_DOCTOR_BOOTS": "1790882097",
               "DOCTORS_DIR": os.path.join(work, "doctors-backfill")}
blank_dir = os.path.join(work, "harness-blank")
os.makedirs(blank_dir)
cold, _ = speed("speed-cold", HARNESS_DOCTOR_DIR=blank_dir, **transcripts)
check(cold["headline"] * cold["window"]["days"] >= doc["headline"] * doc["window"]["days"] > 0
      and cold["selection"] == [p["id"] for p in cold["problems"] if p["rule"] == "opportunity" and p["opportunity"]["recoverable_min_day"] >= 5]
      and all(p["opportunity"]["score"] < 0.2 for p in cold["problems"] if p["id"] == "opportunity:chat/tests")
      and "backfill" not in [b["id"] for b in cold["blind_spots"]],
      "a fresh state with no Harness turn rows backfills every calibration minute from the transcripts: %s %s"
      % (cold["headline"], cold["selection"]))
for folder, harness_at in (("speed-cold", blank_dir), ("speed-both", os.path.join(work, "harness"))):
    speed(folder, "--quiet", HARNESS_DOCTOR_DIR=harness_at, **transcripts)
stored = lambda folder: {os.path.basename(p): json.load(open(p))
                         for p in glob.glob(os.path.join(work, folder, "days", "*.json"))}
both, _ = speed("speed-both", **transcripts)
check(both["headline"] == cold["headline"] and stored("speed-both") == stored("speed-cold")
      and "2026-10-01.json" in stored("speed-both"),
      "backfilled turns Harness already holds count once, prompts included: %s vs %s"
      % (both["headline"], cold["headline"]))
shutil.copytree(os.path.join(work, "speed-cold"), os.path.join(work, "speed-dup"))
for path in glob.glob(os.path.join(work, "speed-dup", "backfill", "*.jsonl")):
    body = open(path).read()
    with open(path, "a") as handle:
        handle.write(body)
speed("speed-dup", "--quiet", HARNESS_DOCTOR_DIR=blank_dir, **transcripts)
check(stored("speed-dup") == stored("speed-cold"),
      "backfill rows appended twice by a run that died before its state.json count once, prompts included")
resumed = os.path.join(work, "speed-resumed")
speed("speed-resumed", "--quiet", HARNESS_DOCTOR_DIR=blank_dir, SPEED_DOCTOR_BACKFILL_S="0", **transcripts)
job = json.load(open(os.path.join(resumed, "state.json")))["backfill"]
step, _ = speed("speed-resumed", HARNESS_DOCTOR_DIR=blank_dir, SPEED_DOCTOR_BACKFILL_S="0", **transcripts)
check(job["files"] == len(job["todo"]) + 1 and not job.get("stored")
      and "backfill" in [b["id"] for b in step["blind_spots"]],
      "a backfill run stops at its budget after one step and leaves the rest for the next run: %d of %d left"
      % (len(job["todo"]), job["files"]))
speed("speed-resumed", "--quiet", HARNESS_DOCTOR_DIR=blank_dir, **transcripts)
os.rename(projects, projects + "-hidden")
done, _ = speed("speed-resumed", HARNESS_DOCTOR_DIR=blank_dir, **transcripts)
os.rename(projects + "-hidden", projects)
job = json.load(open(os.path.join(resumed, "state.json")))["backfill"]
check(not job["todo"] and job["stored"] and done["headline"] == cold["headline"]
      and done["selection"] == cold["selection"] and "backfill" not in [b["id"] for b in done["blind_spots"]],
      "the resumed backfill finishes and later runs read its rows, never the transcripts again: %s" % done["headline"])
job = {"files": 1, "todo": [1]}
while len(job["todo"]) * 2 > job["files"]:
    speed("speed-half", "--quiet", HARNESS_DOCTOR_DIR=blank_dir, SPEED_DOCTOR_BACKFILL_S="0", **transcripts)
    job = json.load(open(os.path.join(work, "speed-half", "state.json")))["backfill"]
half, _ = speed("speed-half", HARNESS_DOCTOR_DIR=blank_dir, SPEED_DOCTOR_BACKFILL_S="0", **transcripts)
same_days = sum(cold["om_by_day"][d] for d in half["om_by_day"]) / max(half["window"]["days"], 0.01)
check(half["coverage"] == {"days": 2.91, "window_days": 7, "backfill_files_done": 21, "backfill_files": 40}
      and set(cold["selection"]) <= set(half["selection"]) and half["why_none"] is None
      and abs(half["headline"] - same_days) <= 0.1 * same_days and min(half["om_by_day"]) == "2026-09-30"
      and "backfill" in [b["id"] for b in half["blind_spots"]] and half["head"].startswith("213 OM/d · 2.9 of 7 days"),
      "a half-done backfill counts only the days it read in full: %s OM/d vs %s over the same days, %s"
      % (half["headline"], round(same_days, 1), half["coverage"]))

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
history = {h.local_day(LO - offset * 86400): {"values": {key: [10.0, 100]}} for offset in range(3, 17)}
history.update({"2026-09-30": {"values": {key: [20.0, 100]}}, "2026-10-01": {"values": {key: [20.0, 100]}}})
check([r["key"] for r in module.judge_regressions(history, "2026-10-02", lambda c: 10.0)[0]] == [key]
      and module.judge_regressions(history, "2026-10-05", lambda c: 10.0)[0] == []
      and module.judge_regressions(dict(history, **{"2026-10-02": history.pop("2026-10-01")}), "2026-10-03",
                                   lambda c: 10.0)[0] == [],
      "only the two closed days right before today, consecutive, are judged: an old or gapped pair stays quiet")

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
pending = {"rows": [{"id": "regression-row", "match": {"rule": "regression", "ident": "chat[.]om_per_100_prompts.*"},
                     "status": "fixed-pending", "fixes": [{"at": h.iso_time(HI - 3600), "files": [], "in": None}]}]}
restated = [(p["id"], p["state"], p["ledger"]) for p in h.apply_speed(copy.deepcopy(harness), red, pending)["problems"]
            if p.get("speed") and p["rule"] == "regression"]
check(restated == [("regression-row", "fixed-pending", "regression-row")],
      "Speed's carried rows read the ledger handed in, as a night close's own branch ledger: %s" % restated)
lines = h.menu_text(merged).splitlines()
check(lines[2].startswith("0\t\tr:") and "Lost time: 1 problem · 3.3 min/day over the floor · 179 OM/d · 3.9 of 7 days covered" in lines[2]
      and lines.index("1\t\t\tWaits: watch · a wait") > 2 and any(l.startswith("0\t") and "Guards: 1 problem" in l
                                                                   for l in lines),
      "the Speed line heads the menu with its count, the Waits section under it, Guards after it: %s" % lines[1:3])

harness_dir = os.path.join(work, "harness")
with open(os.path.join(harness_dir, "latest.json"), "w") as handle:
    json.dump(harness, handle)
own = os.path.join(work, "speed-own")
journals = {"hs": "1\t2\tdoctors:bg\n", "merge-kick": "1\t5\t3\n", "statusline-probes": "1\t5\t3\tports\n",
            "presence": "%d\t5\t-\n" % (HI // 60)}
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
      "a persisting run prunes its hs, merge-kick, statusline-probes and presence days past 35 days and keeps the rest")
with open(os.path.join(work, "doctors", "collector-runs.jsonl")) as handle:
    runs = [json.loads(l) for l in handle]
check([r["doctor"] for r in runs] == ["speed"] and set(runs[0]) == {"doctor", "start", "wall_s", "cpu_s", "trigger"},
      "a persisting run journals its collector row: %s" % runs)
out, _ = speed("speed-own", "--quiet")
latest = json.load(open(os.path.join(harness_dir, "latest.json")))
first = latest["speed"]
menu_txt = open(os.path.join(harness_dir, "menu.txt")).read().splitlines()
check(out.returncode == 0 and first["headline"] == doc["headline"] and counted_once(latest)
      and menu_txt[2] == "0\t\tr:11:9\tLost time: 1 problem · 3.3 min/day over the floor · 179 OM/d · 3.9 of 7 days covered · R 2/10: 88/238"
      and latest["problems"][0]["state"] == "new" and latest["problem_count"] == 3
      and not os.path.exists(os.path.join(own, "latest.json")) and not os.path.exists(os.path.join(own, "menu.txt")),
      "a persisting run lays its section into Harness's latest.json and the top of its menu.txt and writes neither "
      "file of its own; with no baseline the wait keeps its own verdict and counts under Speed: %s" % menu_txt[:2])
budget = first.get("budget") or {}
check(budget.get("lines") and budget["lines"][0].startswith("Without the harness")
      and open(os.path.join(harness_dir, "budget.txt")).read().splitlines() == budget["lines"],
      "a persisting run carries the time budget in its section and writes its plain-words block: %s" % budget.get("lines"))
with open(os.path.join(work, "doctors", "problem-days.jsonl")) as handle:
    days = [json.loads(l) for l in handle]
check([(r["doctor"], r["count"]) for r in days] == [("harness", latest["problem_count"])],
      "the merged document writes Harness's daily problem-count row with the count the menu shows: %s" % days)

header = json.loads(menu_txt[1].removeprefix("H\t"))
state_path = os.path.join(own, "state.json")
state = json.load(open(state_path))
today, yesterday = h.local_day(HI), h.local_day(HI - 86400)
state["lost_min_day_by_day"] = {today: 100, yesterday: 20, "2000-01-01": 900}
with open(state_path, "w") as handle:
    json.dump(state, handle)
speed("speed-own", "--quiet")
repeated = json.load(open(os.path.join(harness_dir, "latest.json")))["speed"]
check(doc.get("lost_min_day_by_day") == first.get("lost_min_day_by_day") == {today: 3.3}
      and header == {"status": latest["status"],
                     "problems": [{k: p[k] for k in ("id", "ledger") if k in p} for p in latest["problems"]],
                     "issues": [[1, "Waits"], [1, "Guards"], [1, "Memory guard"]],
                     "speed": {"as_of_s": first["as_of_s"], "status": first["status"], "lost_min_day": 3.3,
                               "lost_min_day_by_day": {today: 3.3}, "issues": [[3.3, "stop hooks", "min/day"]]},
                     "spend": {"as_of_s": first["as_of_s"], "status": "nodata", "index": None, "index_by_day": {},
                               "issues": []}}
      and repeated.get("lost_min_day_by_day") == json.load(open(state_path)).get("lost_min_day_by_day")
      == {today: 100, yesterday: 20},
      "floor history and compact header preserve daily maxima, prune old days, and invent no OM/d history: %s" % header)

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
                                  "score": 1.0, "recoverable_min_day": 5.0, "hooks": i == "c"}} for i, e in (("a", 1), ("b", 3), ("c", 1), ("d", 1))]
check(module.select(pick) == ["a", "b", "c", "d"], "the pick keeps rank order and no count or hour cap")

repos = base["HARNESS_REPOS_DIR"]
shutil.copytree(os.path.join(root, "tests", "fixtures", "code-doctor", "corpus", "repos", "alpha"),
                os.path.join(repos, "alpha"))
os.makedirs(base["STATUSLINE_CACHE_DIR"])
with open(os.path.join(base["STATUSLINE_CACHE_DIR"], "test-history.jsonl"), "w") as handle:
    for ago, secs in enumerate((300, 310, 290)):
        end = HI - 3600 - ago * 86400
        handle.write(json.dumps({"end": end, "secs": secs, "who": "chat", "repo": "alpha",
                                 "label": "test_isolation"}) + "\n")
        handle.write(json.dumps({"end": end, "secs": 200, "who": "chat", "repo": "alpha", "label": "test_slow"}) + "\n")
        handle.write(json.dumps({"end": end, "secs": 30, "who": "chat", "repo": "alpha", "label": "test_old_sync"}) + "\n")
    for _ in range(2):
        handle.write(json.dumps({"end": HI - 3600, "secs": 400, "who": "chat", "repo": "alpha", "label": "test_once"}) + "\n")
with open(os.path.join(repos, "alpha", "tests", "test_once.sh"), "w") as handle:
    handle.write("#!/bin/bash\n")
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
    tuned, busy = (900000, 900000) if ago in (9, 8) else (0, 0) if ago == 1 else (1000, 900000)
    speed_days[h.local_day(HI - ago * 86400)] = {"hook_cpu_us": {"tuned.sh": [10, tuned * 1000], "busy.sh": [10, busy * 1000],
                                                                 "fresh.sh": [10, 900000 * 1000],
                                                                 "stop.d/part": [10, 50000 * 1000]}}
os.environ.update({k: v for k, v in base.items() if k not in ("HOME", "PATH")}, HARNESS_SETTINGS=settings)
moved = {p["id"]: p for p in module.moved_opportunities(lambda component: 10.0, speed_days, HI)}
check(sorted(moved) == ["opportunity:hooks/busy.sh", "opportunity:tests/alpha/test_isolation",
                        "opportunity:tests/alpha/test_slow"],
      "heavy suites (median >= 120 s) seen on 3 days or in 3 runs and hot hooks become Speed opportunities; a hook counts only days "
      "after its last commit and waits for 3 of them: %s" % sorted(moved))
check(moved["opportunity:hooks/busy.sh"]["opportunity"]["om_day"] == round(10.0 * 2.7e6 / 11.703e6, 2),
      "a hot hook is priced on its days after its last commit, over hook CPU that never sums stop.d parts with "
      "their dispatcher: %s" % moved["opportunity:hooks/busy.sh"]["opportunity"]["om_day"])
check(module.moved_opportunities(lambda component: 0.01, speed_days, HI) == [],
      "a heavy suite or hot hook worth under 0.5 OM/d is no opportunity")
modes = {h.local_day(HI - ago * 86400): {"hook_cpu_us": {"tuned.sh verdict": [10, (900000 if ago > 6 else 1000) * 1000]}}
         for ago in (9, 8, 7, 5, 4, 3)}
check([p for p in module.moved_opportunities(lambda component: 10.0, modes, HI) if p["id"].startswith("opportunity:hooks/")]
      == [], "a mode of a hook (`tuned.sh verdict`, its script registered bare) counts only days after its script's last commit")
with open(os.path.join(hooks_repo, "gone.sh"), "w") as handle:
    handle.write("#!/bin/bash\n")
for ago, args in ((8, ("add", "gone.sh")), (4, ("rm", "-q", "gone.sh"))):
    git(*args)
    stamp = "%d +0000" % (HI - ago * 86400)
    git("commit", "-q", "-m", "gone", GIT_AUTHOR_DATE=stamp, GIT_COMMITTER_DATE=stamp)
os.makedirs(os.path.join(base["HOME"], ".claude"), exist_ok=True)
os.symlink(hooks_repo, os.path.join(base["HOME"], ".claude", "hooks"))
real_home, os.environ["HOME"] = os.environ["HOME"], base["HOME"]
check(module.hook_changed_day("gone.sh x") == h.local_day(HI - 4 * 86400),
      "a hook no settings entry registers any more is charged only after its deletion: %s" % module.hook_changed_day("gone.sh x"))
os.environ["HOME"] = real_home
git("checkout", "-q", "-b", "side")
with open(os.path.join(hooks_repo, "fresh.sh"), "a") as handle:
    handle.write("echo side\n")
git("commit", "-q", "-am", "side", GIT_AUTHOR_DATE="%d +0000" % (HI - 3 * 86400), GIT_COMMITTER_DATE="%d +0000" % (HI - 3 * 86400))
git("checkout", "-q", "-")
git("merge", "-q", "--no-ff", "-m", "land", "side", GIT_AUTHOR_DATE="%d +0000" % (HI - 86400), GIT_COMMITTER_DATE="%d +0000" % (HI - 86400))
check(module.hook_changed_day("fresh.sh") == h.local_day(HI - 86400),
      "a hook commit merged later counts from the merge that landed it: %s" % module.hook_changed_day("fresh.sh"))
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

kick_dir = os.path.join(work, "speed-kicks")
os.makedirs(os.path.join(kick_dir, "merge-kick"))
mid = h.day_start("2026-10-01") + 43200
with open(os.path.join(kick_dir, "merge-kick", "2026-10-01.tsv"), "w") as handle:
    handle.write("%d\t%d\t3\n%d\t%d\t3\n" % ((mid - 600) * 1e6, (mid - 590) * 1e6, (mid + 600) * 1e6, (mid + 610) * 1e6))
os.environ["SPEED_DOCTOR_DIR"] = kick_dir
check(module.background_view({}, mid, mid + 86400, [], 1.0)["merge_kick"]["runs_day"] == 1.0,
      "merge-kick rows before the window's start on its first day are not counted")
os.makedirs(os.path.join(kick_dir, "statusline-probes"))
with open(os.path.join(kick_dir, "statusline-probes", "2026-10-01.tsv"), "w") as handle:
    handle.write("".join("%d\t9\t%s\t%s\n" % (t * 1e6, cpu, kind) for t, cpu, kind in (
        (mid - 600, 60000, "ports"), (mid + 600, 600, "ports"), (mid + 700, 30000, "work"), (mid + 800, 30000, "work"),
        (mid + 900, "-", "work"))))
probe_view = module.background_view({}, mid, mid + 86400, [], 1.0)
check(probe_view["probes"] == {"ports": {"runs_day": 1.0, "cpu_min_day": 0.01}, "work": {"runs_day": 3.0, "cpu_min_day": 1.0}},
      "each statusline probe kind counts its runs and CPU inside the window, a row without CPU as a run only")
check(module.background_share(probe_view, {}) == 1.0,
      "the probes' CPU is the statusline's background share")
labelled = module.machine_view({"2026-10-01": {"label_cpu_s": {"l%d" % i: 90.0 for i in range(10)}}}, 0.0)
check(len(labelled["label_cpu_s"]) == 8
      and abs(module.background_share(probe_view, labelled) - 1.01 / (1.01 + 900 / 60.0 / 1.5)) < 1e-9,
      "the background share divides by every label's CPU over the day files' span, not the top 8 shown: %s"
      % module.background_share(probe_view, labelled))
line_view = module.background_view({"2026-10-01": {"statusline": {"renders": 150, "cpu_ms": 600, "cpu_n": 10}}},
                                   mid, mid + 86400, [], 1.0)
check(line_view["statusline"]["renders_day"] == 100.0 and line_view["statusline"]["cpu_min_day"] == 0.1,
      "a window starting mid-day reads that whole day file, so its statusline rates divide by the files' span: %s"
      % line_view["statusline"])
pre = module.day_values("2026-10-01", {}, {}, None, None, None, [
    {"ended_at": mid, "vendor": "codex", "pid_started_at": mid - 100, "cli_starts": [mid - 95]},
    {"ended_at": mid, "vendor": "codex", "pid_started_at": mid - 100, "cli_starts": [mid - 130]}], None)
check(pre == {"delegation.pre_cli_s|codex|-": [5.0, 1]},
      "a CLI start before its pid start is no pre-CLI time, as in the delegation view: %s" % pre)

nights = os.path.join(work, "doctors", "nights")
os.makedirs(nights, exist_ok=True)
for day in ("2026-09-30", "2026-10-01"):
    start = h.day_start(day) + 7200
    with open(os.path.join(nights, day + ".json"), "w") as handle:
        json.dump({"id": day, "started_at": start, "events": [{"phase": "finish", "at": start + 3 * 3600}],
                   "jobs": [{"state": "merged"}, {"state": "merged"}]}, handle)
speed("speed-nights", "--quiet")
stored = {d: json.load(open(os.path.join(work, "speed-nights", "days", d + ".json")))["values"]
          for d in ("2026-09-30", "2026-10-01")}
check(all(v.get("night.wall_h_per_job|all|-") == [1.5, 2] for v in stored.values()),
      "every closed day keeps the night that started on it, not only the latest night's day: %s" % stored)

events_file = os.path.join(work, "harness", "events", "2026-10-02.jsonl")
before = speed("speed-start")[0]["partition"]["chat"].get("start", 0.0)
with open(events_file, "a") as handle:
    handle.write(json.dumps(["s", Q + 1000, "prof", "chat", 150.0, 400.0, "4242"]) + "\n")
after = speed("speed-start")[0]
check(abs(after["partition"]["chat"].get("start", 0.0) - before - 400.0 / 60.0 / after["window"]["days"]) < 0.02,
      "a chat start waits until its SessionStart ends, never exec plus ready: %s -> %s"
      % (before, after["partition"]["chat"].get("start")))

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

printf 'PASS: %s asserts; speed-doctor turns Harness'"'"'s owner turns and delegations into 179.3 OM/d with its R band, a partition that sums to it, a scored backlog of equivalent levers only (forbidden model/effort/thinking/vendor levers rejected at load, risk levers only as evidenced needs-Egor proposals, yield proven only with output equivalence), presence, presence judged per row (unlogged days keep the R proxy), a resumable transcript backfill for a fresh state counting each turn once, newest files first, its window only the days it read in full (half done: same OM/d as the full fixture over those days, a non-empty pick), short coverage selecting with seen filters scaled and a lower data confidence, a several-day pattern above a one-day spike, two-day regressions, a merge into the Harness document and the top of its menu with each rule counted once, heavy-suite and hot-hook opportunities with their protections, offset reads, a 35-day journal prune and its exec from Harness\n' "$asserts"
