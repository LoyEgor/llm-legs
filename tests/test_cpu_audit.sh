#!/usr/bin/env bash
. "${BASH_SOURCE%"${BASH_SOURCE##*/}"}lib/suite-journal.sh"
# share/cpu_audit.py, the CPU audits block of the Speed doctor, off fixture statusline render and probe journals,
# System doctor hours and doctor collector runs: each component's median over the days its own journal holds, the
# rank, own processes only, the due rules (never, a source blob a Speed landing did not move, x1.5
# CPU-min/day, never under 1 CPU-min/day), the zero option a record must
# carry, a kept audit closing its row with its proof, the restate a night close reads, and no live System hours under
# a fixture Harness directory. Fixture directories only.
set -u
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

asserts=$(python3 - "$ROOT" "$WORK" <<'EOF'
import datetime, json, os, subprocess, sys, time

root, work = sys.argv[1], sys.argv[2]
count = [0]


def check(cond, what):
    count[0] += 1
    if not cond:
        print("FAIL: %s" % what, file=sys.stderr)
        sys.exit(1)


harness, speed, system, repos = (os.path.join(work, d) for d in ("harness", "speed", "system", "repos"))
os.environ.update({"HARNESS_DOCTOR_DIR": harness, "SYSTEM_DOCTOR_DIR": system,
                   "SPEND_LEDGER": os.path.join(work, "spend-ledger.json")})
sys.path.insert(0, os.path.join(root, "share"))
import cpu_audit

NOW = time.mktime((2026, 10, 12, 12, 0, 0, 0, 0, -1))
day = lambda t: time.strftime("%Y-%m-%d", time.localtime(t))
D = lambda back: day(NOW - back * 86400)


def write(path, lines):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w") as handle:
        handle.writelines(line + "\n" for line in lines)


for rel in ("llm-legs/bin/statusline.sh", "llm-legs/bin/statusline-work-probe.sh", "llm-legs/share/statusline-probe.sh",
            "llm-legs/bin/harness-doctor", "hammerspoon/init.lua", "claude-setup/hooks/gate.sh"):
    write(os.path.join(repos, rel), ["v1"])
render = lambda back, sames: write(os.path.join(harness, "statusline", D(back) + ".tsv"),
                                   ["1\t2\tsid\t60000\t" + s for s in sames])
render(2, "110")
render(1, "10")
render(0, "0" * 50)
for back in range(1, 6):
    write(os.path.join(speed, "statusline-probes", D(back) + ".tsv"),
          ["1\t500\t120000\twork"] + (["1\t50\t9000\tports\t-"] if back == 3 else []))
write(os.path.join(system, "hours", D(1) + ".jsonl"),
      [json.dumps({"cpu_top": [["Hammerspoon", 600, 5.0, "own"], ["Safari", 6000, 50.0, "other"]]}),
       json.dumps({"cpu_top": [["Safari", 6000, 50.0, "other"]], "cpu_own": [["tool.py", 120, 0.0, "own"]]})])
collector = [{"doctor": "harness", "start": NOW - 86400, "wall_s": 9, "cpu_s": 30, "trigger": "timer"}]
hooks = [(NOW - 86400, "gate.sh autonomous", 5.0, False, NOW - 86400, "1", 30000.0)]


def collect(state=None):
    return cpu_audit.collect(NOW, {} if state is None else state, harness, speed, collector, hooks, root, repos, day)


first = collect()
ranked = [(c["key"], c["cpu_min_day"]) for c in first["components"]]
check(ranked == [("process/Hammerspoon", 10.0), ("statusline/render", 2.5), ("process/tool.py", 2.0),
                 ("statusline/work", 2.0), ("doctor/harness", 0.5), ("hook/gate.sh", 0.5), ("statusline/ports", 0.0)],
      "each component's CPU-min/day is the median over the settled days its own journal holds, today aside, own "
      "processes only (every one System kept), hooks by script, ranked: %s" % ranked)
shown = {c["key"]: c["wasted_min_day"] for c in first["components"]}
check(shown["statusline/render"] == 1.5 and shown["statusline/work"] is None and shown["statusline/ports"] is None
      and "   1.5 wasted ·       2 runs a day · statusline/render" in first["menu"][1][3]
      and "statusline/render · 2.5 CPU-min/day · 1.5 wasted ·" in first["problems"][1]["fact"],
      "wasted is the median CPU of runs whose output equalled the previous one, unknown without a same column: %s"
      % shown)
check(first["selection"] == ["cpu:" + k for k, v in ranked if v >= 1]
      and {p["cpu"]["due"] for p in first["problems"]} == {"never audited"}
      and all(p["rule"] == "cpu_audit" and p["unit"] == "% CPU" and p["group"] == "CPU audits"
              for p in first["problems"])
      and first["menu"][-1][3].endswith("statusline/ports · under the 1 CPU-min/day floor"),
      "every component never audited is due at 1 CPU-min/day or more, queued in rank order; one under it is never "
      "due: %s" % first["selection"])
check([os.path.relpath(s, repos) for s in first["problems"][1]["cpu"]["sources"]] == ["llm-legs/bin/statusline.sh"]
      and [os.path.relpath(s, repos) for s in first["problems"][3]["cpu"]["sources"]]
      == ["llm-legs/bin/statusline-work-probe.sh", "llm-legs/share/statusline-probe.sh"]
      and [os.path.relpath(s, repos) for s in cpu_audit.sources("hook/gate.sh", repos)] == ["claude-setup/hooks/gate.sh"]
      and [os.path.relpath(s, repos) for s in first["problems"][0]["cpu"]["sources"]] == ["hammerspoon/init.lua"],
      "a component names the sources a fixer opens: %s" % [p["cpu"]["sources"] for p in first["problems"]])
check(first["head"] == "4 due · 3 under 1 CPU-min/day skipped · 18 CPU-min/day over 7 components · next: "
      "process/Hammerspoon", "the block head counts the components the floor skipped: %s" % first["head"])

state = {}
collect(state)
oldest = os.path.join(speed, "statusline-probes", D(5) + ".tsv")
held = os.stat(oldest)
write(oldest, ["1\t500\t990000\twork"])
os.utime(oldest, ns=(held.st_atime_ns, held.st_mtime_ns))
check(collect(state)["components"] == first["components"] and len(state["cpu_files"]) == 9,
      "a day file whose size and mtime hold is read from the state: %s" % sorted(state["cpu_files"]))
write(oldest, ["1\t500\t120000\twork"])

record = lambda key, zero: cpu_audit.record(root, repos, {}, harness, speed, collector, hooks, key, "kept", "fine",
                                            zero, "t", [], NOW, day)
try:
    record("statusline/render", " ")
    refused = False
except SystemExit as error:
    refused = "--zero" in str(error)
check(refused and not os.path.exists(os.environ["SPEND_LEDGER"]),
      "an audit with no zero option (what removing the component saves and loses) is refused, nothing stored")
record("statusline/render", "removal saves 2.5 CPU-min/day; loses every statusline")
kept = collect()
rows = {r["id"]: r for r in json.load(open(os.environ["SPEND_LEDGER"]))["rows"]}
check("cpu:statusline/render" not in kept["selection"] and kept["proofs"]["statusline/render"]["before"] == 2.5
      and rows["cpu:statusline/render"]["zero"] == "removal saves 2.5 CPU-min/day; loses every statusline"
      and rows["cpu:statusline/render"]["sources"] == {"llm-legs/bin/statusline.sh":
                                                        rows["cpu:statusline/render"]["sources"]["llm-legs/bin/statusline.sh"]}
      and any("statusline/render · kept " in m[3] for m in kept["menu"]),
      "a kept audit closes its row and shows its proof: %s" % kept["proofs"])
stale = [p for p in first["problems"] if p["cpu"]["component"] == "statusline/render"]
check(cpu_audit.restate(stale + first["problems"][:1], rows) == first["problems"][:1],
      "a row audited after it was measured is settled for a night close")

write(os.path.join(repos, "llm-legs/bin/statusline.sh"), ["v2"])
moved = {p["cpu"]["component"]: p["cpu"]["due"] for p in collect()["problems"]}
check(moved.get("statusline/render") == "source changed", "a source with another blob reopens the audit: %s" % moved)
record("statusline/render", "removal saves 2.5 CPU-min/day; loses every statusline")
legs = os.path.join(repos, "llm-legs")
git = lambda *args: subprocess.run(["git", "-C", legs] + list(args), check=True, capture_output=True, env=dict(
    os.environ, GIT_AUTHOR_NAME="t", GIT_AUTHOR_EMAIL="t@t", GIT_COMMITTER_NAME="t", GIT_COMMITTER_EMAIL="t@t"))
git("init", "-q")
git("add", "-A")
git("commit", "-qm", "v2")
git("checkout", "-qb", "night/n/harness-speed-cpu-statusline-render-20261012T235118Z-55c2")
write(os.path.join(legs, "bin/statusline.sh"), ["v3"])
git("commit", "-qam", "the render audit's own rebased landing")
git("checkout", "-q", "-")
git("merge", "-q", "--ff-only", "night/n/harness-speed-cpu-statusline-render-20261012T235118Z-55c2")
landed = {p["cpu"]["component"]: p["cpu"]["due"] for p in collect()["problems"]}
write(os.path.join(legs, "bin/statusline.sh"), ["v4"])
git("commit", "-qam", "a chat's edit")
check("statusline/render" not in landed
      and {p["cpu"]["component"]: p["cpu"]["due"] for p in collect()["problems"]}.get("statusline/render")
      == "source changed",
      "a source a Speed audit landing moved leaves its audit closed; a commit main took any other way reopens it: %s"
      % landed)
record("statusline/render", "removal saves 2.5 CPU-min/day; loses every statusline")
render(1, "00000")
risen = {p["cpu"]["component"]: p["cpu"]["due"] for p in collect()["problems"]}
check(risen.get("statusline/render") == "CPU-min/day ×1.6 since audit",
      "CPU-min/day at 1.5x the audit's reopens it: %s" % risen)

import time_budget
lower = dict(kept["proofs"]["statusline/render"], after=1.0)
write(os.path.join(harness, "latest.json"), [json.dumps({"speed": {"cpu": {"proofs": {"statusline/render": lower}}}})])
item = {"ref": "night-x", "class": time_budget.improvement_class("cpu_audit", "cpu:statusline/render"), "spend_m": 1.5,
        "lines": [3, 9], "merged": True}
roi = time_budget.roi_lines([{"started": NOW - 86400, "hours": 2.0, "improvements": [item]}], NOW)
check("cpu_audit" in time_budget.IMPROVEMENT_RULES and time_budget.timed({"improvements": [item]}) == []
      and roi == ["roi · night-x · statusline/render · 1.5M · +3/-9 lines · kept %s · CPU-min/day 2.5 → 1.0 · proven"
                  % lower["audited_at"][:10]],
      "a night's CPU audit reads its proof in the roi lines, out of the minute totals: %s" % roi)

os.environ.pop("SYSTEM_DOCTOR_DIR")
check(cpu_audit.system_dir() is None and "process/Hammerspoon" not in [c["key"] for c in collect()["components"]],
      "a fixture Harness directory with no System directory of its own never reads the live hours")
print(count[0])
EOF
) || { printf 'FAIL: the CPU audits block misjudged its fixture\n' >&2; exit 1; }

printf 'PASS: %s asserts; CPU audits price each component by its median over the days its own journal holds, rank own components (every own process System kept, hooks by script), price wasted CPU off the same column, judge audits due by never/source blob/x1.5 CPU-min/day over a 1 CPU-min/day floor (a Speed landing reopens nothing), refuse a record with no zero option, close a kept audit with its proof and settle it for a night close, and never read live System hours under a fixture Harness directory\n' "$asserts"
