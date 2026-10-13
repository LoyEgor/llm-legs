#!/usr/bin/env bash
. "${BASH_SOURCE%"${BASH_SOURCE##*/}"}lib/suite-journal.sh"
# share/spend.py, the Spend block of the Harness doctor, off a fixture tracking.json: tokenmap's harness_index as the
# headline, the menus check and every Fee index source as components, stale or no index -> nodata, the due rules, the night's ranked queue, the
# restate a night close reads, the audit record and its proof, the roi line, the day backfill and the Harness menu.
# Fixture directories only.
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


sys.path.insert(0, os.path.join(root, "share"))
import spend

repos = os.path.join(work, "repos")
menu_files = [os.path.join(repos, p) for p in ("token-map/tokenmap/tracking.py", "llm-legs/hammerspoon/doctors.lua",
                                                "llm-legs/bin/harness-doctor", "llm-legs/bin/system-doctor")]
for path in menu_files + [os.path.join(repos, "llm-legs", "bin", "worker-run")]:
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w") as handle:
        handle.write("menu\n")
NOW = time.time()


def stamp(t):
    return datetime.datetime.fromtimestamp(t).astimezone().isoformat(timespec="seconds")


def payload(made=NOW - 3600, hook_price=300.0, index=True, value=0.4612, definition="d1", hooks_charged=100e3):
    harness = {"definition": definition, "value": value, "change": "-54%", "tone": "better", "coverage": 0.113,
               "claude": 4e6, "sources": [
                   {"group": "Workers", "source": "Delegation", "plain": [400e3, 300e3], "charged": 300e3},
                   {"group": "Tests & checks", "source": "Hooks", "plain": [100e3, 50e3], "charged": hooks_charged},
                   {"group": "Scripts", "source": "Advisor", "plain": [500e3, 0], "charged": 25e3}],
               "cells": [
        {"consumer": "Chat", "leaf": "Hooks", "source": "Hooks", "units": [100, 50], "price": [hook_price, 200.0],
         "points": -0.1},
        {"consumer": "Chat", "leaf": "prefix: CLAUDE.md + memory", "source": "CLAUDE.md & memory", "units": [100, 50],
         "price": [60.0, 50.0], "points": 0.1},
        {"consumer": "Workers", "leaf": "Delegation", "source": "Delegation", "units": [40, 20], "price": [50.0, 50.0],
         "points": 0.0}]}
    return {"generated_at": stamp(made), "data_through": stamp(NOW), "stale_after_hours": 26,
            **({"harness_index": harness} if index else {}), "rows": [{"key": "spend", "cur": 1e6, "prev": 5e5}]}


found = spend.components(payload(), repos)
check(found[0]["key"] == "menus" and found[0]["sources"] == sorted(menu_files) and found[0]["share"] == 0.0,
      "the menus check comes first, its sources the Token tracking and Doctors menu code, never another bin/ "
      "program: %s" % found[0])
found = {c["key"]: c for c in found}
check([k for k in found][1:] == ["fee:Delegation", "fee:Hooks", "fee:Advisor"]
      and found["fee:Delegation"]["share"] == 70.588 and found["fee:Delegation"]["basis"] == 0.075
      and found["fee:Delegation"]["label"] == "Delegation (Workers)" and found["fee:Delegation"]["delta"] == "+33%"
      and found["fee:Advisor"]["share"] == 5.882 and found["fee:Advisor"]["delta"] == "new",
      "every Fee source of tokenmap's index is a component, largest charge first: its share of Fee as the menu shows "
      "it, its share of Claude spend as the basis, the plain Δ: %s" % found)
check([c["key"] for c in spend.components(payload(index=False), repos)] == ["menus"],
      "no Fee index, no Fee components")

ledger = os.path.join(work, "spend-ledger.json")
os.environ["SPEND_LEDGER"] = ledger
os.environ["SPEND_TRACKING"] = os.path.join(work, "tracking.json")
with open(ledger, "w") as handle:
    json.dump({"owner": "Harness Doctor", "rows": []}, handle)


def collect(made=NOW - 3600, state=None, write=False, **fixture):
    with open(os.environ["SPEND_TRACKING"], "w") as handle:
        json.dump(payload(made, **fixture), handle)
    return spend.collect(NOW, state if state is not None else {}, write, os.path.join(work, "home"), repos, root, lambda t: time.strftime("%Y-%m-%d", time.localtime(t)))


out = collect()
ids = [p["id"] for p in out["problems"]]
check(out["status"] == "watch" and out["index"] == 0.46 and out["change"] == "-54%" and "tone" not in out
      and out["head"] == "Fee index 0.46 (-54%%) · Fee 11.3 %% of spend · %d audits due" % len(ids)
      and ids == ["spend:menus", "spend:fee:Delegation", "spend:fee:Hooks", "spend:fee:Advisor"]
      and all(p["rule"] == "spend_audit" and p["state"] == "watch" and p["fact"].endswith("audit due: never audited")
              for p in out["problems"])
      and out["problems"][1]["fact"] == "70.6 % of Fee · Delegation (Workers) · Δ +33% · audit due: never audited",
      "the headline is tokenmap's harness index; the menus check and every Fee source never audited are due, the "
      "menus first, then by share of Fee: %s %s" % (out["head"], ids))
check(out["selection"] == ids and out["issues"][0] == [70.588, "Delegation (Workers)"],
      "the night's queue is every due audit, largest first; bin/doctor-fix takes its slot share: %s" % out["selection"])
stale_keys = [(r["id"], z) for r in json.load(open(os.path.join(root, "share", "spend-ledger.json")))["rows"]
              for z in r.get("prices") or {} if " · " not in z]
check(not stale_keys, "every recorded audit price is keyed the way part_prices keys it, or proof() never reads it: %s"
      % stale_keys)
check("`spend.selection` lists every due\n  audit" in open(os.path.join(root, "docs", "doctors-contract.md")).read(),
      "docs/doctors-contract.md describes spend.selection as the whole queue the code writes")
stale = collect(made=NOW - 27 * 3600)
check(stale["status"] == "nodata" and stale["index"] is None and stale["problems"] == [] and stale["selection"] == []
      and stale["head"].startswith("tracking.json stale since"),
      "a tracking.json past its stale_after_hours is nodata, never an old index as current: %s" % stale["head"])
missing = collect(index=False)
check(missing["status"] == "nodata" and missing["index"] is None and missing["problems"] == []
      and missing["head"] == "no harness_index in tracking.json",
      "a tracking.json without harness_index is nodata: %s" % missing["head"])
thin = collect(value=None)
check(thin["index"] is None and thin["head"].startswith("Fee index: too little use · ") and thin["problems"],
      "a null index has no value while its audits stay due: %s" % thin["head"])

menus, hooks = found["menus"], found["fee:Hooks"]
source = menu_files[0]
key = spend.repo_path(source, repos)
blob = spend.blobs([source])[source]
held = {spend.repo_path(s, repos): h for s, h in spend.blobs(menus["sources"]).items()}
row = {"id": "menus", "sources": dict(held), "share": 0.0}
check(key == "token-map/tokenmap/tracking.py" and spend.due(menus, None, held) == "never audited"
      and spend.due(menus, row, held) is None
      and spend.due(menus, row, dict(held, **{key: "0" * 40})) == "source changed"
      and spend.due(hooks, {"sources": {}, "share": hooks["basis"] / 1.5}, {}) == "share ×1.5 since audit"
      and spend.due(hooks, {"sources": {}, "share": hooks["basis"] / 1.4}, {}) is None
      and spend.due(hooks, {"sources": {}, "share": hooks["basis"]}, {}) is None,
      "due: never audited, a source blob moved, a share of Claude spend at 1.5x its audit share; unchanged is not "
      "due, and a Fee source, with no source file, is due only by its share")
check(spend.due(hooks, {"sources": {}, "share": 0.0}, {}) is None,
      "an audit recorded at share 0 is never due by share, not ×inf forever")
path = os.environ["PATH"]
os.environ["PATH"] = os.path.join(work, "no-git")
unhashed = spend.blobs([source])
os.environ["PATH"] = path
check(unhashed is None and spend.due(menus, row, None) is None
      and spend.due(hooks, {"sources": {key: None}, "share": hooks["basis"]}, {}) is None
      and spend.due(hooks, {"sources": {key: None}, "share": hooks["basis"]}, {key: blob}) == "source changed",
      "a git that cannot hash leaves every source unmoved, never all due at once; a source recorded absent (a cut "
      "deleted it) and still absent has not moved, one back has")

with open(ledger, "w") as handle:
    json.dump({"owner": "Harness Doctor", "rows": [row, {"id": "fee:Hooks", "sources": {},
                                                       "share": hooks["basis"] / 2}]}, handle)
due_ids = {p["id"]: p["spend"]["due"] for p in collect()["problems"]}
check("spend:menus" not in due_ids and due_ids.get("spend:fee:Hooks") == "share ×2.0 since audit",
      "the collector reads its ledger: the checked unchanged menus leave the list, the risen share returns: %s" % due_ids)
with open(os.path.join(repos, "llm-legs", "bin", "code-doctor"), "w") as handle:
    handle.write("menu\n")
check({p["id"]: p["spend"]["due"] for p in collect()["problems"]}.get("spend:menus") == "source changed",
      "a new doctor is a menu change: the menus check is due again")
os.remove(os.path.join(repos, "llm-legs", "bin", "code-doctor"))
with open(source, "a") as handle:
    handle.write("# changed\n")
check({p["id"]: p["spend"]["due"] for p in collect()["problems"]}.get("spend:menus") == "source changed",
      "a changed menu file makes the menus check due again")

measured = out["problems"][0]
audited = {measured["spend"]["component"]: {"audited_at": stamp(spend.epoch(measured["last_seen"]) + 60)}}
check(spend.restate([measured], audited) == [] and spend.restate([measured], {}) == [measured]
      and spend.restate([measured], {measured["spend"]["component"]: {"audited_at": stamp(NOW - 7200)}}) == [measured],
      "a component audited after Spend measured it is settled for a night close; an older audit is not")

with open(ledger, "w") as handle:
    json.dump({"owner": "Harness Doctor", "rows": []}, handle)
recorded = spend.record(root, os.path.join(work, "home"), repos, "fee:Hooks", "kept",
                        "fires rarely, every block changed the call", "removal saves 0.4 %; loses every block", "night-x", [])
checked = spend.record(root, os.path.join(work, "home"), repos, "menus", "kept", "every new row reaches a doctor",
                       "removal saves 0; loses the night's view of new menu rows", "night-x", [])
stored = json.load(open(ledger))["rows"]
index = json.load(open(os.environ["SPEND_TRACKING"]))["harness_index"]
check(stored == [recorded, checked] and recorded["verdict"] == "kept" and recorded["share"] == hooks["basis"]
      and recorded["zero"] == "removal saves 0.4 %; loses every block" and recorded["sources"] == {}
      and recorded["by"] == "night-x" and recorded["prices"] == {"Chat · Hooks": 300.0}
      and checked["sources"] == {spend.repo_path(s, repos): h for s, h in spend.blobs(menus["sources"]).items()}
      and checked["prices"] == {}
      and spend.part_prices(index, "fee:Delegation") == {"Workers · Delegation": [40.0, 50.0]},
      "the audit record holds the share at audit on the Claude-spend basis, the prices of the index cells the source "
      "is made of, by consumer and leaf, and for the menus check each menu file's blob: %s %s" % (recorded, checked))
try:
    spend.record(root, os.path.join(work, "home"), repos, "fee:Hooks", "maybe", "", "removal saves all", "", [])
    refused = False
except SystemExit:
    refused = True
check(refused, "a verdict other than cut, kept or trade is refused")
before_zero = open(ledger).read()
try:
    spend.record(root, os.path.join(work, "home"), repos, "fee:Hooks", "kept", "", " ", "", [])
    refused = False
except SystemExit:
    refused = True
check(refused and open(ledger).read() == before_zero,
      "an audit with no zero option (what removing the component saves and loses) is refused, nothing stored")
before_git = open(ledger).read()
os.environ["PATH"] = os.path.join(work, "no-git")
try:
    spend.record(root, os.path.join(work, "home"), repos, "menus", "kept", "", "removal saves all", "", [])
    refused = False
except SystemExit:
    refused = True
os.environ["PATH"] = path
check(refused and open(ledger).read() == before_git,
      "a git that cannot hash the sources refuses the record, never stores them absent (a cut) and due at once")
with open(ledger) as handle:
    kept = handle.read()
with open(ledger, "w") as handle:
    handle.write(kept.replace('"rows": [', '"rows": [\n<<<<<<< ours', 1))
broken = open(ledger).read()
try:
    spend.save_row(root, {"id": "fee:Hooks", "verdict": "kept"})
    refused = False
except SystemExit:
    refused = True
check(refused and open(ledger).read() == broken,
      "a ledger that is no JSON (merge conflict markers) refuses the record and keeps its rows, never overwritten")
with open(ledger, "w") as handle:
    handle.write(kept)
before = collect()
later = time.time() + 60
same, cheaper = (collect(made=later, hook_price=price)["proofs"].get("fee:Hooks") for price in (300.0, 150.0))
check(before["proofs"] == {} and any(l[3].endswith("· kept %s · not measured since" % recorded["audited_at"][:10])
                                     for l in before["menu"])
      and same == {"share": 1.0, "price": 1.0, "proven": False, "verdict": "kept", "audited_at": recorded["audited_at"]}
      and cheaper and cheaper["price"] == 0.5 and cheaper["share"] == 1.0 and cheaper["proven"],
      "an audit is proven once a measurement after it shows its share or its part's price lower: %s %s" % (same, cheaper))

sys.path.insert(0, os.path.join(root, "share"))
import time_budget
os.environ["HARNESS_DOCTOR_DIR"] = os.path.join(work, "harness")
os.makedirs(os.environ["HARNESS_DOCTOR_DIR"])
with open(os.path.join(work, "harness", "latest.json"), "w") as handle:
    json.dump({"speed": {"spend": {"proofs": {"fee:Hooks": cheaper}}}}, handle)
item = {"ref": "night-x", "class": time_budget.improvement_class("spend_audit", "spend:fee:Hooks"), "spend_m": 1.5,
        "lines": [3, 9], "merged": True}
check("spend_audit" in time_budget.IMPROVEMENT_RULES
      and time_budget.roi_lines([{"started": NOW - 86400, "hours": 2.0, "improvements": [item]}], NOW)
      == ["roi · night-x · fee:Hooks · 1.5M · +3/-9 lines · share ×1.0 · price ×0.5 of audit · proven"],
      "a night's Spend audit reads its proof in the roi lines, out of the minute totals")

fake = os.path.join(work, "tokenmap")
with open(os.path.join(work, "day.json"), "w") as handle:
    json.dump(payload(value=0.7), handle)
with open(fake, "w") as handle:
    handle.write('#!/bin/sh\necho "$*" >> %s/tokenmap.calls\ncat %s/day.json\n' % (work, work))
os.chmod(fake, 0o755)
day = lambda t: time.strftime("%Y-%m-%d", time.localtime(t))
shift = lambda d, n: (datetime.date.fromisoformat(d) + datetime.timedelta(days=n)).isoformat()
state = {}
collect(state=state, write=True)
check(state == {"index_by_day": {day(NOW - 3600): 0.46}, "index_definition": "d1", "index_closed": []}
      and not os.path.exists(os.path.join(work, "tokenmap.calls")),
      "a run stores the reading's index under its day; a fixture tracking.json with "
      "no fixture tokenmap never reaches the live index: %s" % state)
os.environ["SPEND_TOKENMAP"] = fake
first = collect(state=state, write=True)
missing_day = day(NOW - 86400)
calls = open(os.path.join(work, "tokenmap.calls")).read().splitlines()
check(state["index_by_day"] == {day(NOW - 3600): 0.46, missing_day: 0.7} and first["index_by_day"] == state["index_by_day"]
      and state["index_closed"] == [missing_day]
      and calls == ["tracking --since %s --until %s --json" % (shift(missing_day, -6), shift(missing_day, 1))],
      "one missing completed day a run from tokenmap's 7-day window ending it, stored as its index: %s %s"
      % (state["index_by_day"], calls))
collect(state=state, write=True)
check(len(state["index_closed"]) == 2 and len(open(os.path.join(work, "tokenmap.calls")).read().splitlines()) == 2,
      "the next run takes the next missing day: %s" % state["index_by_day"])
collect(state=state, write=False)
check(len(state["index_closed"]) == 2, "a read-only run backfills nothing")
failing = os.path.join(work, "tokenmap-failing")
with open(failing, "w") as handle:
    handle.write("#!/bin/sh\nexit 1\n")
os.chmod(failing, 0o755)
os.environ["SPEND_TOKENMAP"] = failing
collect(state=state, write=True)
os.environ["SPEND_TOKENMAP"] = fake
held_days = len(state["index_closed"])
collect(state=state, write=True)
check(held_days == 2 and len(state["index_closed"]) == 3 and None not in state["index_by_day"].values(),
      "a failed tokenmap run stores no day, so the next run retries it instead of a permanent gap: %s"
      % state["index_by_day"])

provisional = {"index_by_day": {missing_day: 0.46}, "index_definition": "d1"}
collect(state=provisional, write=True)
check(provisional["index_by_day"][missing_day] == 0.7 and provisional["index_closed"] == [missing_day],
      "a day read intraday is provisional: once it closes, the backfill replaces it with the closed day's value: %s"
      % provisional)

redefined = {"index_by_day": dict(state["index_by_day"]), "index_definition": "d1",
             "index_closed": list(state["index_closed"])}
collect(state=redefined, write=False, definition="d2")
check(redefined == {"index_by_day": {}, "index_definition": "d2", "index_closed": []},
      "history recorded under another index definition is dropped, never charted beside the new one: %s" % redefined)

with open(ledger, "w") as handle:
    json.dump({"owner": "Harness Doctor", "rows": []}, handle)
loader = importlib.machinery.SourceFileLoader("harness_doctor", os.path.join(root, "bin", "harness-doctor"))
h = importlib.util.module_from_spec(importlib.util.spec_from_loader("harness_doctor", loader))
loader.exec_module(h)
section = collect()
problems = section.pop("problems")
document = {"problem_count": 0, "status": "ok", "as_of_s": int(NOW), "title": "Harness doctor: ok", "problems": [],
            "sections": [], "footer": "as of now"}
h.apply_speed(document, {"problems": problems, "spend": section, "menu": [], "head": "x"}, {"rows": []})
lines = h.menu_text(document).splitlines()
header = json.loads(lines[1][2:])
spent = [p for p in document["problems"] if p["rule"] == "spend_audit"]
check(document["problem_count"] == 0 and spent and all(p["group"] == "Spend" and p["speed"] for p in spent)
      and lines[2].startswith("0\t\t\tLost time: ok")
      and "0\t\t\tSpend: watch · Fee index 0.46 (-54%%) · Fee 11.3 %% of spend · %d audits due" % len(spent) in lines
      and "1\t\t\tToken tracking and Doctors menus against what the night reads · audit due: never audited" in lines
      and "1\t\t\t70.6 % of Fee · Delegation (Workers) · Δ +33% · audit due: never audited" in lines
      and header["spend"] == {k: section[k] for k in ("as_of_s", "status", "index", "index_by_day", "change",
                                                      "issues")},
      "Harness lays Spend beside Lost time: watch rows counted nowhere, its block and its header: %s" % lines[:6])
print(count[0])
EOF
) || { printf 'FAIL: the Spend block misjudged its fixture\n' >&2; exit 1; }

printf 'PASS: %s asserts; Spend heads with tokenmap'"'"'s harness index, audits the menus check and every Fee index source off tracking.json, reads stale or no index as nodata, judges audits due by never/source blob/1.5x share, selects one, settles an audited one for a night close, records audits with their proof and roi line and backfills one day a run\n' "$asserts"
