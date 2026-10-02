#!/usr/bin/env bash
# hammerspoon/doctors.lua over fixture documents and run records: titles, Fix, fixer rows, Updater rows.
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }

command -v hs >/dev/null 2>&1 || { echo "   (skipped: Hammerspoon CLI is unavailable)"; exit 0; }

# One vocabulary: the areas bin/doctor-fix gives these documents become night fixer jobs, and the
# harness checks each label bin/night-run gives them against the rows the Doctors menu shows.
VOCAB=$(mktemp -d)
trap 'rm -rf "$VOCAB"' EXIT
now=$(date +%s)
mkdir -p "$VOCAB/home" "$VOCAB/runs" "$VOCAB/projects" "$VOCAB/doctors/nights"
printf '{"owner": "o", "owners": {}, "rows": [], "blind_spots": []}\n' >"$VOCAB/llm-ledger.json"
printf '{"rows": []}\n' >"$VOCAB/harness-ledger.json"
printf '{"rows": []}\n' >"$VOCAB/updater-ledger.json"
printf '{"owner": "o", "rows": []}\n' >"$VOCAB/code-ledger.json"
jq -n --argjson s "$now" '{contract: 1, doctor: "code", as_of_s: $s, judge: "c", status: "problems", problem_count: 1,
  groups: {dead: 1, heavy: 0, duplicate: 0}, blind_spots: [],
  problems: [{id: "cause:repo/bin/x", rule: "unreachable", group: "dead", state: "new", fact: "x is dead", value: 9,
    units: [], files: ["repo/bin/x"]}]}' >"$VOCAB/code.json"
printf '{}\n' >"$VOCAB/settings.json"
jq -n --argjson s "$now" '["reviewers", "workers", "light", "image"] as $blocks
  | {contract: 1, doctor: "llm", as_of_s: $s, judge: "j", status: "problems", problem_count: 6, window_h: 24,
     blocks: [$blocks[] | {block: ., bugs: 1, weather: 0, legs: 1,
       problems: [{id: "leg-failure:\(.)/crashed", label: "crashed", count: 1, kind: "bug"}]}],
     health: [{name: "debt", status: "problem", count: 1, items: [], notes: [], rules: [{rule: "debt-gap", key: "x"}]}],
     problems: ([$blocks[] | {id: "leg-failure:\(.)/crashed", rule: "leg-failure", state: "new", fact: "crashed"}]
       + [{id: "debt-gap:x", rule: "debt-gap", state: "new", fact: "a debt gap"},
          {id: "ledger:R1", rule: "ledger", state: "new", fact: "a ledger fault"}])}' >"$VOCAB/llm.json"
jq -n --argjson s "$now" '{contract: 1, doctor: "updater", as_of_s: $s, judge: "u", status: "problems", problem_count: 1,
  problems: [{id: "pass-stale:codex", rule: "pass-stale", state: "new", fact: "stale pass"}], blind_spots: [],
  vendors: [{vendor: "codex", installed: "0.1.0", latest: "0.1.0", models: [], events: []}]}' >"$VOCAB/updater.json"
python3 - "$ROOT" "$VOCAB" "$now" <<'PY' || fail "the harness fixture document was not built"
import importlib.machinery, importlib.util, json, sys

root, out, now = sys.argv[1], sys.argv[2], int(sys.argv[3])
loader = importlib.machinery.SourceFileLoader("harness_doctor", root + "/bin/harness-doctor")
module = importlib.util.module_from_spec(importlib.util.spec_from_loader(loader.name, loader))
loader.exec_module(module)
parts = {"Hooks": "hook_every_call", "Hook waits": "floor", "Load": "load"}
sections = [module.section(name, [module.row([rule], red=[0], judge=[module.verdict(rule, "x", 1, 0, "calls", 1, 1, "red")])],
                           [""], [False]) for name, rule in parts.items()]
problems = [{"id": rule + ":x", "rule": rule, "state": "new", "fact": rule} for rule in parts.values()]
problems.append({"id": "collector:run", "rule": "collector", "state": "new", "fact": "slow collector"})
document = {"contract": 1, "doctor": "harness", "as_of_s": now, "judge": "h", "status": "problems",
            "problem_count": len(problems), "problems": problems, "title": "Harness doctor: %d problems" % len(problems),
            "sections": sections, "periods": {}, "extras": [], "footer": "as of now"}
json.dump(document, open(out + "/harness.json", "w"))
open(out + "/menu.txt", "w").write(module.menu_text(document))
PY
eval "$(sed -n "/^PY='\$/,/^'\$/p" "$ROOT/bin/doctor-fix")"
for doctor in llm harness updater code; do
  HOME="$VOCAB/home" LLM_DOCTOR_LEDGER="$VOCAB/llm-ledger.json" HARNESS_LEDGER="$VOCAB/harness-ledger.json" \
    UPDATER_DOCTOR_LEDGER="$VOCAB/updater-ledger.json" HARNESS_SETTINGS="$VOCAB/settings.json" \
    CODE_DOCTOR_LEDGER="$VOCAB/code-ledger.json" CODE_DOCTOR_DIR="$VOCAB/code-doctor" CODE_DOCTOR_REPOS="" \
    DF_ROOT="$ROOT" DF_PROJECTS="$VOCAB/projects" DF_RUNS="$VOCAB/runs" DF_HOME="$VOCAB/home" DF_DOCS="$ROOT/docs" \
    python3 -c "$PY" snapshot "$doctor" "$VOCAB/$doctor.json" |
    jq -r --arg d "$doctor" '[.[].area] | unique[] | "\($d)-\(.)-20261001T020000Z-abcd"' ||
    fail "doctor-fix did not snapshot the $doctor fixture"
done >"$VOCAB/refs"
[ "$(wc -l <"$VOCAB/refs" | tr -d ' ')" = 12 ] || fail "doctor-fix areas of the fixtures: $(tr '\n' ' ' <"$VOCAB/refs")"
printf '%s\n' llm-health-20261001T020000Z-abcd harness-self-20261001T020000Z-abcd \
  updater-machinery-20261001T020000Z-abcd >>"$VOCAB/refs"
jq -Rn --arg s "$(date -u +%Y-%m-%dT%H:%M:%SZ)" '{id: "n1", started_at: $s, finished_at: $s, note: null,
  jobs: ([inputs | {kind: "fixer", ref: ., state: "pending", reason: null}]
    + [{kind: "vendor", ref: "updater-release-20261001T020000Z-abcd", branch: "night/n1/codex", state: "pending", reason: null}])}' \
  <"$VOCAB/refs" >"$VOCAB/doctors/nights/n1.json"
DOCTORS_DIR="$VOCAB/doctors" bash "$ROOT/bin/night-run" latest --menu | tail -n +2 | awk -F'\t' '$5 != "doctor"' | cut -f1 >"$VOCAB/labels.txt"
[ "$(wc -l <"$VOCAB/labels.txt" | tr -d ' ')" = 16 ] || fail "night-run labels: $(tr '\n' ' ' <"$VOCAB/labels.txt")"

output=$(python3 - "$ROOT/tests/doctors_menu_harness.lua" "$VOCAB" <<'HSPY'
import subprocess
import sys

try:
    result = subprocess.run(["hs", "-c", f"return loadfile([[{sys.argv[1]}]])([[{sys.argv[2]}]])"],
                            stdin=subprocess.DEVNULL, capture_output=True, text=True, timeout=30)
except (FileNotFoundError, subprocess.TimeoutExpired):
    raise SystemExit(124)
sys.stdout.write(result.stdout)
sys.stderr.write(result.stderr)
raise SystemExit(result.returncode)
HSPY
) || fail "the Hammerspoon harness threw or timed out: $output"
result=$(printf '%s\n' "$output" | grep -v '^-- Loading extension: ' | awk '/^(PASS|FAIL)/ { found = 1 } found')
case "$result" in
  PASS:*) echo "OK: $result" ;;
  *) fail "${result:-$output}" ;;
esac
