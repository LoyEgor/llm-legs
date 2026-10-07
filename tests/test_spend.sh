#!/usr/bin/env bash
. "${BASH_SOURCE%"${BASH_SOURCE##*/}"}lib/suite-journal.sh"
# share/spend.py, the Spend block of the Harness doctor, off a fixture tracking.json: components summed per hook script
# over tokenmap's three Hooks sections, stale -> nodata, the due rules, the night's one selection, the restate a night
# close reads, the audit record, the day backfill and the Harness menu. Fixture directories only.
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


def payload(made=NOW - 3600):
    return {"generated_at": stamp(made), "data_through": stamp(NOW), "stale_after_hours": 26, "rows": [
        {"key": "spend", "cur": 1e6, "prev": 5e5},
        {"key": "bench", "cur": 2e5, "prev": 1e5},
        {"key": "hooks", "sections": [
            rows("Blocked calls", [("gate.sh", ["10k", "5k"], 0), ("17 more", ["3k", "1k"], 1)]),
            rows("Stop-hook re-answers", [("Stop [drill.sh]", ["20k", "0"], 0)]),
            rows("Injected text", [("PreToolUse:Bash · gate ran this", ["30k", "10k"], 0)])]},
        {"key": "resumes", "cur": 5e4, "prev": 1e4},
        {"key": "rewrites", "sections": [rows("By cause", [("expired (1h+ idle)", ["60k", "50k"], 0),
                                                            ("expired (5m ttl)", ["30k", "<0.1M"], 0)])]},
        {"key": "startup", "cur": 1e5, "prev": 1e5, "sections": [rows("Per context that loads it (avg)", [
            ("CLAUDE.md + memory index", ["6.0k", "5.0k"], 0), ("system + tools (not in total)", ["7.9k", "7.1k"], 1),
            ("skill listing", ["4.0k", "5.0k"], 0)])]},
        {"key": "hidden", "sections": [rows("Compaction summaries, by zone", [("worker", ["5k", "1k"], 0),
                                                                             ("chat", ["15k", "4k"], 0)])]},
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
check(found["startup:CLAUDE.md + memory index"]["share"] == 6.0 and found["compaction"]["share"] == 2.0
      and found["resumes"]["share"] == 5.0 and not found["rewrites:expired (1h+ idle)"]["avoidable"]
      and found["rewrites:expired (5m ttl)"]["avoidable"],
      "startup parts split the startup total by their per-context size; compaction sums its zones; a cause tokenmap "
      "deems unavoidable is shown, never targeted: %s" % {k: (c["share"], c["avoidable"]) for k, c in found.items()})

ledger = os.path.join(work, "spend-ledger.json")
os.environ["SPEND_LEDGER"] = ledger
os.environ["SPEND_TRACKING"] = os.path.join(work, "tracking.json")
with open(ledger, "w") as handle:
    json.dump({"owner": "Harness Doctor", "rows": []}, handle)


def collect(made=NOW - 3600, state=None, write=False):
    with open(os.environ["SPEND_TRACKING"], "w") as handle:
        json.dump(payload(made), handle)
    return spend.collect(NOW, state if state is not None else {}, write, scripts, os.path.join(work, "home"),
                         os.path.join(work, "repos"), root, lambda t: time.strftime("%Y-%m-%d", time.localtime(t)))


out = collect()
ids = [p["id"] for p in out["problems"]]
check(out["status"] == "watch" and out["share"] == 26.0
      and ids[:3] == ["spend:startup:CLAUDE.md + memory index", "spend:resumes", "spend:hook:gate.sh"]
      and "spend:rewrites:expired (1h+ idle)" not in ids
      and all(p["rule"] == "spend_audit" and p["state"] == "watch" and p["fact"].endswith("audit due: never audited")
              for p in out["problems"]),
      "every avoidable component never audited is due, ranked by share; the value sums the avoidable shares: %s %s"
      % (out["share"], ids))
check(out["selection"] == ["spend:startup:CLAUDE.md + memory index"] and out["issues"][0] == [6.0, "startup CLAUDE.md + memory index"],
      "the night selects exactly one audit, the top-ranked due component: %s" % out["selection"])
stale = collect(made=NOW - 27 * 3600)
check(stale["status"] == "nodata" and stale["share"] is None and stale["problems"] == [] and stale["selection"] == []
      and stale["head"].startswith("tracking.json stale since"),
      "a tracking.json past its stale_after_hours is nodata, never an old share as current: %s" % stale["head"])

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
      and recorded["sources"] == {key: spend.blobs([source])[source]} and recorded["by"] == "night-x",
      "the audit record holds each source's blob, the share at audit on tokenmap's Δ basis, the verdict: %s" % recorded)
try:
    spend.record(root, os.path.join(work, "home"), os.path.join(work, "repos"), scripts, "hook:gate.sh", "maybe", "", "", [])
    refused = False
except SystemExit:
    refused = True
check(refused, "a verdict other than cut, kept or trade is refused")

fake = os.path.join(work, "tokenmap")
with open(os.path.join(work, "day.json"), "w") as handle:
    json.dump(payload(), handle)
with open(fake, "w") as handle:
    handle.write('#!/bin/sh\necho "$*" >> %s/tokenmap.calls\ncat %s/day.json\n' % (work, work))
os.chmod(fake, 0o755)
state = {}
collect(state=state, write=True)
check(state.get("spend_by_day") == {} and not os.path.exists(os.path.join(work, "tokenmap.calls")),
      "a fixture tracking.json with no fixture tokenmap never reaches the live index")
os.environ["SPEND_TOKENMAP"] = fake
first = collect(state=state, write=True)
yesterday = time.strftime("%Y-%m-%d", time.localtime(NOW - 86400))
calls = open(os.path.join(work, "tokenmap.calls")).read().splitlines()
check(state["spend_by_day"] == {yesterday: 26.0} and first["share_by_day"] == state["spend_by_day"] and len(calls) == 1
      and calls[0].startswith("tracking --since %s --until " % yesterday) and calls[0].endswith("--json"),
      "one completed day a run from tokenmap's own window over it, stored as the doctor's daily value: %s %s"
      % (state["spend_by_day"], calls))
collect(state=state, write=True)
check(len(state["spend_by_day"]) == 2 and len(open(os.path.join(work, "tokenmap.calls")).read().splitlines()) == 2,
      "the next run takes the next missing day: %s" % state["spend_by_day"])
collect(state=state, write=False)
check(len(state["spend_by_day"]) == 2, "a read-only run backfills nothing")

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
      and lines[2].startswith("0\t\t\tLost time: ok") and "0\t\t\tSpend: watch · 26.0 %% of spend · %d audits due" % len(spent) in lines
      and "1\t\t\t6.0 % · startup CLAUDE.md + memory index · Δ -40% · audit due: never audited" in lines
      and header["spend"] == {k: section[k] for k in ("as_of_s", "status", "share", "share_by_day", "issues")},
      "Harness lays Spend beside Lost time: watch rows counted nowhere, its block and its header: %s" % lines[:6])
print(count[0])
EOF
) || { printf 'FAIL: the Spend block misjudged its fixture\n' >&2; exit 1; }

printf 'PASS: %s asserts; Spend prices harness components off tracking.json per hook script, reads stale as nodata, judges audits due by never/source blob/1.5x share, selects one, settles an audited one for a night close, records audits and backfills one day a run\n' "$asserts"
