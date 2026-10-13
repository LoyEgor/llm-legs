#!/usr/bin/env bash
. "${BASH_SOURCE%"${BASH_SOURCE##*/}"}lib/suite-journal.sh"
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
eval "$(sed -n "/^PY='\$/,/^'\$/p" "$ROOT/bin/doctor-fix")"
HOME="$VOCAB/home" LLM_DOCTOR_LEDGER="$VOCAB/llm-ledger.json" HARNESS_LEDGER="$VOCAB/harness-ledger.json" \
  UPDATER_DOCTOR_LEDGER="$VOCAB/updater-ledger.json" HARNESS_SETTINGS="$VOCAB/settings.json" \
  CODE_DOCTOR_LEDGER="$VOCAB/code-ledger.json" CODE_DOCTOR_DIR="$VOCAB/code-doctor" CODE_DOCTOR_REPOS="" \
  DF_ROOT="$ROOT" DF_PROJECTS="$VOCAB/projects" DF_RUNS="$VOCAB/runs" DF_HOME="$VOCAB/home" DF_DOCS="$ROOT/docs" \
  python3 - "$PY" "$VOCAB" "$now" >"$VOCAB/refs" <<'PY' || fail "the harness fixture document was not built or doctor-fix did not snapshot the fixtures"
import contextlib, io, json, sys

doctor_fix = {"__name__": "doctor_fix"}
exec(compile(sys.argv[1], "doctor-fix", "exec"), doctor_fix)
out, now = sys.argv[2], int(sys.argv[3])
module = doctor_fix["doctor_module"]("harness")
parts = {"Hooks": "hook_every_call", "Hook waits": "floor", "Load": "load"}
sections = [module.section(name, [module.row([rule], red=[0], judge=[module.verdict(rule, "x", 1, 0, "calls", 1, 1, "red")])],
                           [""], [False]) for name, rule in parts.items()]
problems = [{"id": rule + ":x", "rule": rule, "state": "new", "fact": rule, "expected_min_day": 5} for rule in parts.values()]
problems.append({"id": "collector:run", "rule": "collector", "state": "new", "fact": "slow collector"})
document = {"contract": 1, "doctor": "harness", "as_of_s": now, "judge": "h", "status": "problems",
            "problem_count": len(problems), "problems": problems, "title": "Harness doctor: %d problems" % len(problems),
            "sections": sections, "periods": {}, "extras": [], "footer": "as of now"}
json.dump(document, open(out + "/harness.json", "w"))
open(out + "/menu.txt", "w").write(module.menu_text(document))
for doctor in ("llm", "harness", "updater", "code"):
    snapshot = io.StringIO()
    with contextlib.redirect_stdout(snapshot):
        doctor_fix["snapshot"](doctor, "%s/%s.json" % (out, doctor))
    for area in sorted({entry["area"] for entry in json.loads(snapshot.getvalue())}):
        print("%s-%s-20261001T020000Z-abcd" % (doctor, area))
PY
[ "$(wc -l <"$VOCAB/refs" | tr -d ' ')" = 12 ] || fail "doctor-fix areas of the fixtures: $(tr '\n' ' ' <"$VOCAB/refs")"
printf '%s\n' llm-health-20261001T020000Z-abcd harness-self-20261001T020000Z-abcd \
  updater-machinery-20261001T020000Z-abcd >>"$VOCAB/refs"
jq -Rn --arg s "$(date -u +%Y-%m-%dT%H:%M:%SZ)" '{id: "n1", started_at: $s, finished_at: $s, note: null,
  jobs: ([inputs | {kind: "fixer", ref: ., state: "pending", reason: null}]
    + [{kind: "vendor", ref: "updater-release-20261001T020000Z-abcd", branch: "night/n1/codex", state: "pending", reason: null}])}' \
  <"$VOCAB/refs" >"$VOCAB/doctors/nights/n1.json"
DOCTORS_DIR="$VOCAB/doctors" bash "$ROOT/bin/night-run" latest --menu | tail -n +2 | awk -F'\t' '$5 != "doctor"' | cut -f1 >"$VOCAB/labels.txt"
[ "$(wc -l <"$VOCAB/labels.txt" | tr -d ' ')" = 16 ] || fail "night-run labels: $(tr '\n' ' ' <"$VOCAB/labels.txt")"

source=nil only=false baseline=nil
[ -z "${DOCTORS_MENU_SOURCE:-}" ] || source="[[$DOCTORS_MENU_SOURCE]]"
[ -z "${DOCTORS_MENU_TRENDS_ONLY:-}" ] || only=true
[ -z "${DOCTORS_MENU_BASELINE:-}" ] || baseline="[[$DOCTORS_MENU_BASELINE]]"
output=$(/usr/bin/lockf -k -t 600 /tmp/hs-cli.lock hs -t 120 \
  -c "return loadfile([[$ROOT/tests/doctors_menu_harness.lua]])([[$VOCAB]], $source, $only, $baseline)" </dev/null) ||
  fail "the Hammerspoon harness threw or timed out: $output"
printf '%s\n' "$output" | awk '/^(BENCH|FIXTURE|SUBMENU) /'
result=$(printf '%s\n' "$output" | grep -v '^-- Loading extension: ' | awk '/^(PASS|FAIL)/ { found = 1 } found')
case "$result" in
  PASS:*) echo "OK: $result" ;;
  *) fail "${result:-$output}" ;;
esac
