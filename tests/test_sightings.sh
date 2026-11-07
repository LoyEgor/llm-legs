#!/usr/bin/env bash
. "${BASH_SOURCE%"${BASH_SOURCE##*/}"}lib/suite-journal.sh"
# share/sightings.py: what the doctors saw over 14 days, so a night after a gap still finds a problem a window rule
# forgot, ranked by its loss over those days (Egor 2026-11-07).
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK="$(mktemp -d)"
WORK="$(cd -P "$WORK" && pwd)"
trap 'rm -rf "$WORK"' EXIT
asserts=0
jqe() { jq -e "$@" >/dev/null; }

export HOME="$WORK/home" DOCTORS_DIR="$WORK/doctors" LLM_DOCTOR_DIR="$WORK/llm" HARNESS_DOCTOR_DIR="$WORK/harness" \
  UPDATER_DOCTOR_DIR="$WORK/updater" CODE_DOCTOR_DIR="$WORK/code" SYSTEM_DOCTOR_DIR="$WORK/system" \
  LLM_DOCTOR_LEDGER="$WORK/ledger.json"
mkdir -p "$HOME" "$DOCTORS_DIR/runs" "$WORK"/{llm,harness,updater,code,system}
STORE="$DOCTORS_DIR/sightings.json"
pyq() { python3 -B -c "import sys; sys.path.insert(0, '$ROOT/share'); $1"; }
NOW=$(date +%s)
day() { date -r $((NOW - $1 * 86400)) +%Y-%m-%d; }
TODAY=$(day 0) D1=$(day 1) OLD=$(day 20)
row() { # id state window_h value [extra-json]
  jq -nc --arg id "$1" --arg s "$2" --argjson w "$3" --argjson v "$4" --argjson x "${5:-{\}}" \
    '{id: $id, rule: "leg-failure", state: $s, window_h: $w, value: $v, unit: "min", fact: "\($id) fact"} + $x'
}
doc() { # doctor status problem-json...
  local doctor=$1 status=$2
  shift 2
  jq -n --arg d "$doctor" --arg st "$status" --argjson now "$NOW" '{contract: 1, doctor: $d, as_of: ($now | todate),
    status: $st, problems: $ARGS.positional | map(fromjson), blind_spots: [], self: {collector_s: 0.1, error: null}}' \
    --args "$@" >"$WORK/$doctor/latest.json"
}

# A fixture doctor directory with no DOCTORS_DIR of its own never reads or writes the live store.
assert [ "$(env -u DOCTORS_DIR python3 -B -c "import sys; sys.path.insert(0, '$ROOT/share'); import sightings as s; print(s.store_path(), s.record())")" = "None None" ]

# Recording: a day older than 14 is dropped; yesterday's sighting stays. Only live window problems are recorded:
# a watched one and a state rule's (no window) are not.
jq -n --arg old "$OLD" --arg d1 "$D1" --argjson last $((NOW - 86400)) --argjson y "$(row Y new 24 10)" \
  '{llm: {covered: [$old, $d1], problems: {
     Z: {days: {($old): 5}, last: 1, problem: {id: "Z"}},
     Y: {days: {($d1): 10}, last: $last, problem: $y}}}}' >"$STORE"
doc llm problems "$(row A new 24 30)" "$(row F new 24 1)" "$(row G new 24 1 '{"ledger": "R1"}')" \
  "$(row W watch 24 99)" "$(row S new null 99)"
doc harness ok
pyq "import sightings; sightings.record()" || fail "record failed"
assert jqe --arg t "$TODAY" --arg d1 "$D1" '.llm.covered == [$d1, $t] and (.llm.problems | keys) == ["A", "F", "G", "Y"]
  and .llm.problems.A.days[$t] == 30 and .llm.problems.Y.days == {($d1): 10} and .harness.covered == [$t]' "$STORE"
# The day keeps its highest reading.
doc llm problems "$(row A new 24 12)" "$(row F new 24 1)" "$(row G new 24 1 '{"ledger": "R1"}')"
pyq "import sightings; sightings.record()"
assert jqe --arg t "$TODAY" '.llm.problems.A.days[$t] == 30' "$STORE"

# The average is over the covered days, a day not seen counting zero.
assert [ "$(pyq "import sightings as s; print(s.min_day('llm', 'A'), s.min_day('llm', 'Y'), s.min_day('llm', 'S'))")" = "15.0 5.0 None" ]

# Missing: what the document no longer lists, biggest first, its fact led by when it was last seen. Left out: a live id,
# an open row (the night's known, quiet), a row not ours, a row fixed after the last sighting; a fix before it stays.
doc llm problems
missing() { pyq "import json, sightings as s; print(json.dumps(s.missing('llm', set($1), $2)))"; }
missing '["G"]' "{'R1': {'status': 'weather'}, 'F': {'status': 'fixed', 'fixes': [{'at': $((NOW + 60))}]}}" >"$WORK/m.json"
assert jqe '[.[].id] == ["A", "Y"]' "$WORK/m.json"
assert jqe --arg y "not seen since $(date -r $((NOW - 86400)) '+%b %d') · 5.0 min/day over 2 days · Y fact" \
  '.[1].fact == $y and .[1].seen.min_day == 5 and .[1].state == "new" and (.[1].evidence[0].ref == "sightings:Y")' "$WORK/m.json"
missing '[]' "{'R1': {'status': 'open'}, 'F': {'status': 'fixed', 'fixes': [{'at': '2026-01-01T00:00:00Z'}]}}" >"$WORK/m.json"
assert jqe '[.[].id] == ["A", "Y", "F"]' "$WORK/m.json"
assert [ "$(missing '["A", "Y", "F", "G"]' '{}')" = "[]" ]

# The night's snapshot queues them after the live problems; a ruling after the last sighting holds one out.
eval "$(sed -n "/^PY='\$/,/^'\$/p" "$ROOT/bin/doctor-fix")"
printf '{"owner": "LLM owner", "owners": {}, "rows": [{"id": "R1", "title": "r", "match": {"word": "x"}, "status": "weather", "fixes": []}], "blind_spots": []}\n' \
  >"$LLM_DOCTOR_LEDGER"
snapshot() {
  DF_ROOT="$ROOT" DF_PROJECTS="$WORK/projects" DF_RUNS="$DOCTORS_DIR/runs" DF_HOME="$HOME" DF_DOCS="$ROOT/docs" \
    python3 -c "$PY" snapshot llm "$WORK/llm/latest.json" "" 2>"$WORK/snap.err"
}
doc llm problems "$(row L new 24 2)"
snapshot >"$WORK/snap.json" || fail "snapshot failed: $(cat "$WORK/snap.err")"
assert jqe '[.. | objects | select(has("fact") and has("id")) | .id] as $ids | ($ids | index("L")) < ($ids | index("A"))
  and ($ids | index("Y")) != null and ($ids | index("G")) == null' "$WORK/snap.json"
assert grep -qF '"fact": "not seen since' "$WORK/snap.json"
jq -n --argjson t $((NOW - 10)) '{id: "llm-ruled", doctor: "llm", closed_at: ($t | todate), problems: [{id: "Y"}],
  decisions: [{id: "Y", verdict: "ruled-out"}]}' >"$DOCTORS_DIR/runs/llm-ruled.json"
snapshot >"$WORK/snap.json"
assert jqe '[.. | objects | select(.id == "Y")] == [{id: "Y", state: "held", run: "llm-ruled"}]' "$WORK/snap.json"

# Ranking: a measured row's wall-min/day is its 14-day average once it has one; a priced gain keeps its own.
jq -n --arg t "$TODAY" '{harness: {covered: $ARGS.positional, problems: {H: {days: {($t): 40}}}}}' \
  --args $(for back in $(seq 0 10); do day "$back"; done) >"$STORE"
prio() { pyq "import json, night_priority as n; print(json.dumps(n.priority('harness', $1)[1:3]))"; }
assert [ "$(prio "{'id': 'H', 'rule': 'hook_p50', 'value': 40, 'unit': 'min/day'}")" = '["P2", 3.64]' ]
assert [ "$(prio "{'id': 'N', 'rule': 'hook_p50', 'value': 40, 'unit': 'min/day'}")" = '["P1", 40.0]' ]
assert [ "$(prio "{'id': 'H', 'rule': 'hook_p50', 'value': 40, 'unit': 'min/day', 'expected_min_day': 20}")" = '["P1", 20.0]' ]

echo "PASS: test_sightings ($asserts asserts)"
