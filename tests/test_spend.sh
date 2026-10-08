#!/usr/bin/env bash
. "${BASH_SOURCE%"${BASH_SOURCE##*/}"}lib/suite-journal.sh"
# share/spend.py, the Spend block of the Harness doctor, off a fixture tracking.json: tokenmap's harness_index as the
# headline, components summed per hook script over tokenmap's three Hooks sections, only harness-owned ones targeted
# (re-writes by tokenmap's avoidable flag), stale or no index -> nodata, the due rules, the night's one selection, the
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

hooks = os.path.join(work, "repos", "setup", "hooks")
os.makedirs(os.path.join(hooks, "stop.d"))
for name, text in (("gate.sh", 'echo "gate ran this in a subshell"\n'), ("stop-dispatch.sh", "run stop.d\n"),
                   ("stop.d/drill.sh", "echo drill\n"), ("other.sh", "echo other\n")):
    with open(os.path.join(hooks, name), "w") as handle:
        handle.write(text)
os.makedirs(os.path.join(work, "home", ".claude"))
with open(os.path.join(work, "home", ".claude", "settings.json"), "w") as handle:
    json.dump({"hooks": {"PreToolUse": [{"hooks": [{"command": os.path.join(hooks, "gate.sh")}]}],
                         "Stop": [{"hooks": [{"command": os.path.join(hooks, "stop-dispatch.sh")}]}]}}, handle)
scripts = [os.path.join(hooks, "gate.sh"), os.path.join(hooks, "stop-dispatch.sh")]
NOW = time.time()


def stamp(t):
    return datetime.datetime.fromtimestamp(t).astimezone().isoformat(timespec="seconds")


def rows(title, items):
    return {"title": title, "rows": [{"label": l, "cells": c, **({"dim": True} if d else {})} for l, c, d in items]}


def payload(made=NOW - 3600, idle_avoidable=False, hook_price=300.0, index=True, value=0.4612):
    causes = rows("By cause", [("expired (1h+ idle)", ["70k", "50k"], 0), ("expired (5m ttl)", ["30k", "<0.1M"], 0)])
    for cause, avoidable in zip(causes["rows"], (idle_avoidable, True)):
        cause["avoidable"] = avoidable
    harness = {"value": value, "change": "-54%", "tone": "better", "coverage": 0.113, "parts": [
        {"part": "hooks", "zone": "chat", "units": [100, 50], "price": [hook_price, 200.0], "points": -0.1},
        {"part": "startup", "zone": "chat", "units": [10, 8], "price": [6000.0, 5000.0], "points": 0.1},
        {"part": "startup", "zone": "subagent", "units": [4, 2], "price": [5000.0, 5000.0], "points": 0.0}]}
    return {"generated_at": stamp(made), "data_through": stamp(NOW), "stale_after_hours": 26,
            **({"harness_index": harness} if index else {}), "rows": [
        {"key": "spend", "cur": 1e6, "prev": 5e5},
        {"key": "bench", "cur": 2e5, "prev": 1e5},
        {"key": "hooks", "sections": [
            rows("Blocked calls", [("gate.sh", ["10k", "5k"], 0), ("17 more", ["3k", "1k"], 1)]),
            rows("Stop-hook re-answers", [("Stop [drill.sh]", ["20k", "0"], 0)]),
            rows("Injected text", [("PreToolUse:Bash · gate ran this", ["30k", "10k"], 0)])]},
        {"key": "resumes", "cur": 5e4, "prev": 1e4},
        {"key": "rewrites", "sections": [causes]},
        {"key": "startup", "cur": 1.2e5, "prev": 1.1e5, "sections": [rows("Per context that loads it (avg)", [
            ("CLAUDE.md + memory index", ["6.0k", "5.0k"], 0), ("system + tools (not in total)", ["7.9k", "7.1k"], 1),
            ("skill listing", ["4.0k", "5.0k"], 0), ("nested CLAUDE.md files", ["10.0k", "1.0k"], 0)]),
            rows("Main contexts, total by part", [
                ("CLAUDE.md + memory index", ["60k", "50k"], 0), ("system + tools (not in total)", ["79k", "71k"], 1),
                ("skill listing", ["39k", "49k"], 0), ("nested CLAUDE.md files", ["1k", "1k"], 0)]),
            rows("Subagent spawns, by agent", [
                ("claudeb-worker", ["20k", "10k"], 0)])]},
        {"key": "hidden", "sections": [rows("Compaction summaries, by zone", [("worker", ["5k", "1k"], 0),
                                                                             ("chat", ["150k", "4k"], 0)])]},
        {"key": "thinking", "cur": 3e5, "prev": 1e5}]}


files = spend.hook_files(scripts)
found = {c["key"]: c for c in spend.components(payload(), files, spend.file_texts())}
gate = found["hook:gate.sh"]
check(gate["cur"] == 40000 and gate["sources"] == [os.path.realpath(os.path.join(hooks, "gate.sh"))]
      and gate["share"] == 4.0 and gate["delta"] == "+33%",
      "a hook script sums its Blocked calls and Injected text rows, the text resolved by its opening words, with "
      "tokenmap's share and its Δ on the outside-review-bench basis: %s" % gate)
check(found["hook:drill.sh"]["cur"] == 20000 and found["hook:drill.sh"]["sources"]
      == [os.path.realpath(os.path.join(hooks, "stop.d", "drill.sh"))],
      "a Stop-hook re-answer names its script in brackets; a stop.d part beside the dispatcher resolves: %s"
      % found["hook:drill.sh"])
check(not [k for k in found if "17 more" in k or "system + tools" in k] and "thinking" not in found,
      "the dim tail rows and the model's own spend (thinking) are no component: %s" % sorted(found))
check(found["startup:CLAUDE.md + memory index"]["share"] == 6.0 and found["startup:nested CLAUDE.md files"]["share"] == 0.1
      and found["compaction"]["share"] == 15.5
      and found["spawn:claudeb-worker"]["share"] == 2.0 and found["spawn:claudeb-worker"]["target"]
      and found["resumes"]["share"] == 5.0 and not found["rewrites:expired (1h+ idle)"]["target"]
      and found["rewrites:expired (5m ttl)"]["target"] and not found["compaction"]["target"],
      "spawns are their own components and startup parts split the rest by tokenmap's main-context totals, never "
      "by the per-context averages that inflate a rarely loaded part; compaction sums "
      "its zones and, like a cause tokenmap does not flag avoidable, is shown, never targeted: %s"
      % {k: (c["share"], c["target"]) for k, c in found.items()})
flipped = {c["key"]: c["target"] for c in spend.components(payload(idle_avoidable=True), files, spend.file_texts())}
check(flipped["rewrites:expired (1h+ idle)"] and found["rewrites:expired (5m ttl)"]["target"],
      "the avoidable flag is read from tracking.json: flipping it in the fixture makes the cause a target")

ledger = os.path.join(work, "spend-ledger.json")
os.environ["SPEND_LEDGER"] = ledger
os.environ["SPEND_TRACKING"] = os.path.join(work, "tracking.json")
with open(ledger, "w") as handle:
    json.dump({"owner": "Harness Doctor", "rows": []}, handle)


def collect(made=NOW - 3600, state=None, write=False, **fixture):
    with open(os.environ["SPEND_TRACKING"], "w") as handle:
        json.dump(payload(made, **fixture), handle)
    return spend.collect(NOW, state if state is not None else {}, write, scripts, os.path.join(work, "home"),
                         os.path.join(work, "repos"), root, lambda t: time.strftime("%Y-%m-%d", time.localtime(t)))


out = collect()
ids = [p["id"] for p in out["problems"]]
check(out["status"] == "watch" and out["index"] == 0.46 and out["change"] == "-54%" and out["tone"] == "better"
      and out["head"] == "index 0.46 (-54%%) · 11.3 %% of spend priced · %d audits due" % len(ids)
      and ids[:3] == ["spend:startup:CLAUDE.md + memory index", "spend:resumes", "spend:hook:gate.sh"]
      and "spend:rewrites:expired (1h+ idle)" not in ids and "spend:compaction" not in ids
      and "spend:spawn:claudeb-worker" in ids
      and all(p["rule"] == "spend_audit" and p["state"] == "watch" and p["fact"].endswith("audit due: never audited")
              for p in out["problems"]),
      "the headline is tokenmap's harness index; every harness-owned component never audited is due, ranked by "
      "share, the largest (compaction) never among them: %s %s" % (out["head"], ids))
check([p["id"] for p in collect(idle_avoidable=True)["problems"]][0] == "spend:rewrites:expired (1h+ idle)",
      "a cause tokenmap flags avoidable becomes a target and, the largest, the first audit")
check(out["selection"] == ["spend:startup:CLAUDE.md + memory index"] and out["issues"][0] == [6.0, "startup CLAUDE.md + memory index"],
      "the night selects exactly one audit, the top-ranked due component: %s" % out["selection"])
stale = collect(made=NOW - 27 * 3600)
check(stale["status"] == "nodata" and stale["index"] is None and stale["problems"] == [] and stale["selection"] == []
      and stale["head"].startswith("tracking.json stale since"),
      "a tracking.json past its stale_after_hours is nodata, never an old index as current: %s" % stale["head"])
missing = collect(index=False)
check(missing["status"] == "nodata" and missing["index"] is None and missing["problems"] == []
      and missing["head"] == "no harness_index in tracking.json",
      "a tracking.json without harness_index is nodata: %s" % missing["head"])
thin = collect(value=None)
check(thin["index"] is None and thin["head"].startswith("harness index: too little use · ") and thin["problems"],
      "a null index has no value while its audits stay due: %s" % thin["head"])

source = gate["sources"][0]
key = spend.repo_path(source, os.path.join(work, "repos"))
blob = spend.blobs([source])[source]
row = {"id": "hook:gate.sh", "sources": {key: blob}, "share": gate["basis"]}
check(key == "setup/hooks/gate.sh" and spend.due(gate, None, {key: blob}) == "never audited"
      and spend.due(gate, row, {key: blob}) is None
      and spend.due(gate, row, {key: "0" * 40}) == "source changed"
      and spend.due(gate, dict(row, share=gate["basis"] / 1.5), {key: blob}) == "share ×1.5 since audit"
      and spend.due(gate, dict(row, share=gate["basis"] / 1.4), {key: blob}) is None
      and spend.due(found["resumes"], {"sources": {}, "share": found["resumes"]["basis"]}, {}) is None
      and spend.due(found["resumes"], {"sources": {}, "share": found["resumes"]["basis"] / 2}, {}) == "share ×2.0 since audit",
      "due: never audited, a source blob moved, a share at 1.5x its audit share; unchanged is not due, and a "
      "component with no source file is due only by its share")
path = os.environ["PATH"]
os.environ["PATH"] = os.path.join(work, "no-git")
unhashed = spend.blobs([source])
os.environ["PATH"] = path
check(unhashed is None and spend.due(gate, row, None) is None
      and spend.due(found["resumes"], {"sources": {key: None}, "share": found["resumes"]["basis"]}, {}) is None
      and spend.due(found["resumes"], {"sources": {key: None}, "share": found["resumes"]["basis"]}, {key: blob})
      == "source changed",
      "a git that cannot hash leaves every source unmoved, never all due at once; a source recorded absent (a cut "
      "deleted it) and still absent has not moved, one back has")

with open(ledger, "w") as handle:
    json.dump({"owner": "Harness Doctor", "rows": [row, {"id": "resumes", "sources": {},
                                                       "share": found["resumes"]["basis"] / 2}]}, handle)
again = collect()
due_ids = {p["id"]: p["spend"]["due"] for p in again["problems"]}
check("spend:hook:gate.sh" not in due_ids and due_ids.get("spend:resumes") == "share ×2.0 since audit",
      "the collector reads its ledger: the audited unchanged hook leaves the list, the risen share returns: %s" % due_ids)
with open(source, "a") as handle:
    handle.write("# changed\n")
check({p["id"]: p["spend"]["due"] for p in collect()["problems"]}.get("spend:hook:gate.sh") == "source changed",
      "an audited hook whose script changed is due again")

measured = out["problems"][0]
audited = {measured["spend"]["component"]: {"audited_at": stamp(spend.epoch(measured["last_seen"]) + 60)}}
check(spend.restate([measured], audited) == [] and spend.restate([measured], {}) == [measured]
      and spend.restate([measured], {measured["spend"]["component"]: {"audited_at": stamp(NOW - 7200)}}) == [measured],
      "a component audited after Spend measured it is settled for a night close; an older audit is not")

with open(ledger, "w") as handle:
    json.dump({"owner": "Harness Doctor", "rows": []}, handle)
recorded = spend.record(root, os.path.join(work, "home"), os.path.join(work, "repos"), scripts, "hook:gate.sh", "kept",
                        "fires rarely, every block changed the call", "night-x", [])
stored = json.load(open(ledger))["rows"]
check(stored == [recorded] and recorded["verdict"] == "kept" and recorded["share"] == gate["basis"]
      and recorded["sources"] == {key: spend.blobs([source])[source]} and recorded["by"] == "night-x"
      and recorded["prices"] == {"chat": 300.0},
      "the audit record holds each source's blob, the share at audit on tokenmap's Δ basis, its harness_index part's "
      "prices by zone, the verdict: %s" % recorded)
try:
    spend.record(root, os.path.join(work, "home"), os.path.join(work, "repos"), scripts, "hook:gate.sh", "maybe", "", "", [])
    refused = False
except SystemExit:
    refused = True
check(refused, "a verdict other than cut, kept or trade is refused")
with open(ledger) as handle:
    kept = handle.read()
with open(ledger, "w") as handle:
    handle.write(kept.replace('"rows": [', '"rows": [\n<<<<<<< ours', 1))
broken = open(ledger).read()
try:
    spend.save_row(root, {"id": "resumes", "verdict": "kept"})
    refused = False
except SystemExit:
    refused = True
check(refused and open(ledger).read() == broken,
      "a ledger that is no JSON (merge conflict markers) refuses the record and keeps its rows, never overwritten")
with open(ledger, "w") as handle:
    handle.write(kept)
before = collect()
later = time.time() + 60
same, cheaper = (collect(made=later, hook_price=price)["proofs"].get("hook:gate.sh") for price in (300.0, 150.0))
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
    json.dump({"speed": {"spend": {"proofs": {"hook:gate.sh": cheaper}}}}, handle)
item = {"ref": "night-x", "class": time_budget.improvement_class("spend_audit", "spend:hook:gate.sh"), "spend_m": 1.5,
        "lines": [3, 9], "merged": True}
check("spend_audit" in time_budget.IMPROVEMENT_RULES
      and time_budget.roi_lines([{"started": NOW - 86400, "hours": 2.0, "improvements": [item]}], NOW)
      == ["roi · night-x · hook:gate.sh · 1.5M · +3/-9 lines · share ×1.0 · price ×0.5 of audit · proven"],
      "a night's Spend audit reads its proof in the roi lines, out of the minute totals")

fake = os.path.join(work, "tokenmap")
with open(os.path.join(work, "day.json"), "w") as handle:
    json.dump(payload(value=0.7), handle)
with open(fake, "w") as handle:
    handle.write('#!/bin/sh\necho "$*" >> %s/tokenmap.calls\ncat %s/day.json\n' % (work, work))
os.chmod(fake, 0o755)
day = lambda t: time.strftime("%Y-%m-%d", time.localtime(t))
shift = lambda d, n: (datetime.date.fromisoformat(d) + datetime.timedelta(days=n)).isoformat()
state = {"spend_by_day": {day(NOW - 86400): 26.0}}
collect(state=state, write=True)
check(state == {"index_by_day": {day(NOW - 3600): 0.46}} and not os.path.exists(os.path.join(work, "tokenmap.calls")),
      "a run stores the reading's index under its day and drops the old share history; a fixture tracking.json with "
      "no fixture tokenmap never reaches the live index: %s" % state)
os.environ["SPEND_TOKENMAP"] = fake
first = collect(state=state, write=True)
missing_day = next(d for d in (day(NOW - b * 86400) for b in range(1, 8)) if d != day(NOW - 3600))
calls = open(os.path.join(work, "tokenmap.calls")).read().splitlines()
check(state["index_by_day"] == {day(NOW - 3600): 0.46, missing_day: 0.7} and first["index_by_day"] == state["index_by_day"]
      and calls == ["tracking --since %s --until %s --json" % (shift(missing_day, -6), shift(missing_day, 1))],
      "one missing completed day a run from tokenmap's 7-day window ending it, stored as its index: %s %s"
      % (state["index_by_day"], calls))
collect(state=state, write=True)
check(len(state["index_by_day"]) == 3 and len(open(os.path.join(work, "tokenmap.calls")).read().splitlines()) == 2,
      "the next run takes the next missing day: %s" % state["index_by_day"])
collect(state=state, write=False)
check(len(state["index_by_day"]) == 3, "a read-only run backfills nothing")

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
      and "0\t\t\tSpend: watch · index 0.46 (-54%%) · 11.3 %% of spend priced · %d audits due" % len(spent) in lines
      and "1\t\t\t6.0 % · startup CLAUDE.md + memory index · Δ -40% · audit due: never audited" in lines
      and "1\td\t\t15.5 % · compaction summaries · Δ ×16 · never targeted" in lines
      and header["spend"] == {k: section[k] for k in ("as_of_s", "status", "index", "index_by_day", "change", "tone",
                                                      "issues")},
      "Harness lays Spend beside Lost time: watch rows counted nowhere, its block and its header: %s" % lines[:6])
print(count[0])
EOF
) || { printf 'FAIL: the Spend block misjudged its fixture\n' >&2; exit 1; }

printf 'PASS: %s asserts; Spend heads with tokenmap'"'"'s harness index, prices harness components off tracking.json per hook script, targets only harness-owned ones, reads stale or no index as nodata, judges audits due by never/source blob/1.5x share, selects one, settles an audited one for a night close, records audits with their proof and roi line and backfills one day a run\n' "$asserts"
