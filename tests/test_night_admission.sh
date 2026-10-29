#!/usr/bin/env bash
. "${BASH_SOURCE%"${BASH_SOURCE##*/}"}lib/suite-journal.sh"
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK="$(mktemp -d)"
WORK="$(cd -P "$WORK" && pwd)"
trap 'kill $(cat "$WORK/pids" 2>/dev/null) 2>/dev/null; rm -rf "$WORK"' EXIT
asserts=0
jqe() { jq -e "$@" >/dev/null; }

FAKE_BIN="$WORK/bin" NIGHTS="$WORK/doctors/nights"
export HOME="$WORK/home" DOCTORS_DIR="$WORK/doctors" WORKER_RUN_DIR="$WORK/runs" LLM_LIMITS_FILE="$WORK/limits.json" \
  LLM_DOCTOR_DIR="$WORK/llm" HARNESS_DOCTOR_DIR="$WORK/harness" UPDATER_DOCTOR_DIR="$WORK/updater" \
  CODE_DOCTOR_DIR="$WORK/code" SYSTEM_DOCTOR_DIR="$WORK/system" HARNESS_HOLDS_DIR="$WORK/holds" \
  NIGHT_RUN_WORKER_PICK="$FAKE_BIN/worker-pick" NIGHT_RUN_SWEEP_REPOS="$WORK/sweep-repos" NIGHT_RUN_HELPER_REPOS=/dev/null \
  NIGHT_RUN_ADMIT_POLL_S=1 TOKENMAP_SPEND_7D="$WORK/none.json" NIGHT_RUN_REVIEW_DEBT=/usr/bin/false
mkdir -p "$FAKE_BIN" "$NIGHTS" "$DOCTORS_DIR/runs" "$WORKER_RUN_DIR" "$HOME" "$WORK"/{llm,harness,updater,code,system}
: >"$WORK/sweep-repos"
: >"$WORK/pids"
printf '#!/usr/bin/env bash\nprintf "claudeb\\tacct\\t10\\tok\\nclaudeb\\toff-acct\\t0\\toff\\n"\n' >"$FAKE_BIN/worker-pick"
chmod +x "$FAKE_BIN/worker-pick"
night() { bash "$ROOT/bin/night-run" "$@"; }
pyq() { python3 -B -c "import sys; sys.path.insert(0, '$ROOT/share'); $1"; }
live_pid() { sleep 600 & printf '%s\n' "$!" >>"$WORK/pids"; LIVE=$!; }
limits() { # h5 week days-left: one pool account, plus an account outside the pool that never counts
  local reset
  reset=$(date -u -r $(($(date +%s) + $3 * 86400)) +%Y-%m-%dT%H:%M:%SZ)
  jq -n --argjson h5 "$1" --argjson wk "$2" --arg r "$reset" --argjson now "$(date +%s)" '{vendors: {claude: {accounts: [
    {account: "acct", five_hour: {used_pct: $h5, as_of: $now, resets_at: "2099-01-01T00:00:00Z"}, weekly: {used_pct: $wk, as_of: $now, resets_at: $r}},
    {account: "off-acct", five_hour: {used_pct: 0, as_of: $now, resets_at: "2099-01-01T00:00:00Z"}, weekly: {used_pct: 0, as_of: $now, resets_at: $r}}]}}}' \
    >"$LLM_LIMITS_FILE"
}
suite_row() { # id wall-min/day
  jq -nc --arg id "$1" --argjson v "$2" '{id: $id, rule: "suite_audit", state: "watch", value: $v, unit: "wall-min/day", speed: true,
    fact: "\($v) wall-min/day"}'
}
fixer() { # ref problem-id...
  local ref=$1
  shift
  jq -n --arg ref "$ref" --args '{id: $ref, doctor: "harness", area: "speed-x", problems: [$ARGS.positional[] | {id: ., rule: "suite_audit"}]}' "$@" \
    >"$DOCTORS_DIR/runs/$ref.json"
}
jq -n --argjson p "[$(suite_row s:big 40),$(suite_row s:mid 5),$(suite_row s:small 0.2),
  {\"id\": \"cpu:x\", \"rule\": \"cpu_audit\", \"state\": \"watch\", \"speed\": true, \"cpu\": {\"cpu_min_day\": 500}}]" \
  '{problem_count: 4, problems: $p}' >"$WORK/harness/latest.json"
fixer f-big s:big
fixer f-mid s:mid
fixer f-mid2 s:mid
fixer f-small s:small
fixer f-cpu cpu:x
fixer f-gone s:vanished
jq '.problems[0].fact = "t · 22.5 wall-min/day"' "$DOCTORS_DIR/runs/f-gone.json" >"$WORK/r" && mv "$WORK/r" "$DOCTORS_DIR/runs/f-gone.json"
id=20261013T000000Z-test
jq -n --arg id "$id" '{id: $id, started_at: "2026-10-13T00:00:00Z", finished_at: null, session: null, jobs: [], events: []}' \
  >"$NIGHTS/$id.json"
job() { jq -c --arg r "$1" '.jobs[] | select(.ref == $r)' "$NIGHTS/$id.json"; }

# Priority: measured value against named bars; CPU is never P1; other kinds by what they are.
for ref in f-big f-mid f-mid2 f-small f-cpu f-gone; do night job "$id" add fixer "$ref" >/dev/null || fail "job add $ref"; done
night job "$id" add vendor ev-1 >/dev/null || fail "job add vendor"
assert jqe '.priority == "P1" and .direction == "updater"' <<<"$(job ev-1)"
assert jqe '.priority == "P1" and .direction == "tests" and .value.n == 40' <<<"$(job f-big)"
assert jqe '.priority == "P2" and .direction == "tests"' <<<"$(job f-mid)"
assert jqe '.priority == "P3"' <<<"$(job f-small)"
assert jqe '.priority == "P2" and .direction == "cpu"' <<<"$(job f-cpu)"
assert jqe '.priority == "P1" and .value.n == 22.5' <<<"$(job f-gone)"

# Pacing: 20 % of 5h room (80 - 60) carries two runs at the default 7 % each; the third waits, never dropped.
limits 60 10 1
live_pid; big=$LIVE
night admit "$id" f-big claudeb "$big" >"$WORK/out" || fail "the first P1 was not admitted"
live_pid; gone=$LIVE
night admit "$id" f-gone claudeb "$gone" >/dev/null || fail "the second P1 was not admitted"
assert jqe '.admission.state == "admitted" and .admission.cost == 7' <<<"$(job f-gone)"
live_pid; mid=$LIVE
night admit "$id" f-mid claudeb "$mid" >"$WORK/mid.out" 2>&1 &
mid_gate=$!
live_pid; mid2=$LIVE
sleep 0.5
night admit "$id" f-mid2 claudeb "$mid2" >"$WORK/mid2.out" 2>&1 &
mid2_gate=$!
sleep 2.5
assert kill -0 "$mid_gate"
assert jqe '.state == "pending" and .admission.state == "waiting"' <<<"$(job f-mid)"
assert test "$(ls "$HARNESS_HOLDS_DIR" | grep -c night-admission)" -ge 1
kill "$big"
wait "$mid_gate" || fail "a waiter was not admitted once a running job ended"
assert grep -q 'admitted' "$WORK/mid.out"
assert kill -0 "$mid2_gate"
kill "$gone"
wait "$mid2_gate" || fail "the second waiter was not admitted"

# Order: the P1 waiter goes first even though the P2 one waited longer.
limits 79 10 1
night job "$id" add fixer f-late >/dev/null
fixer f-p1 s:big
night job "$id" add fixer f-p1 >/dev/null
night job "$id" set f-mid state=merged >/dev/null
night job "$id" set f-mid2 state=merged >/dev/null
live_pid; p2=$LIVE
live_pid; p1=$LIVE
out=$(printf '[{"account":"acct","h5":79,"wk":10,"days_left":1,"ceiling":80}]' |
  python3 -B "$ROOT/share/night_priority.py" admit "$NIGHTS/$id.json" f-late claudeb "$p2")
assert test "${out%%$'\t'*}" = admit
live_pid; blocker=$LIVE
jq --arg r f-late --argjson p "$blocker" '(.jobs[] | select(.ref == $r) | .admission.pid) = $p' "$NIGHTS/$id.json" >"$WORK/n" &&
  mv "$WORK/n" "$NIGHTS/$id.json"
fixer f-wait s:mid
night job "$id" add fixer f-wait >/dev/null
for pair in "f-wait $p2" "f-p1 $p1"; do
  set -- $pair
  out=$(printf '[{"account":"acct","h5":79,"wk":10,"days_left":1,"ceiling":80}]' |
    python3 -B "$ROOT/share/night_priority.py" admit "$NIGHTS/$id.json" "$1" claudeb "$2")
  assert test "${out%%$'\t'*}" = wait
done
kill "$blocker"
out=$(printf '[{"account":"acct","h5":79,"wk":10,"days_left":1,"ceiling":80}]' |
  python3 -B "$ROOT/share/night_priority.py" admit "$NIGHTS/$id.json" f-wait claudeb "$p2")
assert test "${out%%$'\t'*}" = wait
out=$(printf '[{"account":"acct","h5":79,"wk":10,"days_left":1,"ceiling":80}]' |
  python3 -B "$ROOT/share/night_priority.py" admit "$NIGHTS/$id.json" f-p1 claudeb "$p1")
assert test "${out%%$'\t'*}" = admit

# P3: only out of weekly room that would expire unused; without it the job is deferred, pending, and left at the close.
limits 0 90 3
live_pid
rc=0; night admit "$id" f-small claudeb "$LIVE" >"$WORK/out" 2>&1 || rc=$?
assert test "$rc" -eq 3
assert grep -q 'deferred' "$WORK/out"
assert jqe '.state == "pending" and .admission.state == "deferred"' <<<"$(job f-small)"
# A lens coverage slice is a P3 job of its lens's direction, admitted the same way.
night job "$id" add coverage coverage-legacy-1 >/dev/null || fail "job add coverage"
assert jqe '.priority == "P3" and .direction == "legacy"' <<<"$(job coverage-legacy-1)"
assert [ "$(python3 -B "$ROOT/share/night_priority.py" job coverage coverage-tests-1 | jq -c '[.direction, .priority]')" = '["tests","P3"]' ]
rc=0; night admit "$id" coverage-legacy-1 claudeb "$LIVE" >/dev/null 2>&1 || rc=$?
assert test "$rc" -eq 3
limits 0 10 1
live_pid
night admit "$id" f-small claudeb "$LIVE" >/dev/null || fail "a P3 with expiring weekly room was not admitted"
assert jqe '.admission.state == "admitted"' <<<"$(job f-small)"
night admit "$id" coverage-legacy-1 claudeb "$LIVE" >/dev/null || fail "a coverage slice with expiring weekly room was not admitted"

# Cost by model: a Sonnet run holds token-map's Sonnet price share of an Opus run (2 of 4 per MTok), so 11 % of
# room carries an Opus run and a Sonnet one (night 20261029T012849Z-5e69: a Sonnet P3 waited 26 min at the Opus price).
id2=20261013T000000Z-model
jq -n --arg id "$id2" '{id: $id, started_at: "2026-10-13T00:00:00Z", finished_at: null, session: null, jobs: [], events: []}' \
  >"$NIGHTS/$id2.json"
for ref in f-mid f-mid2; do night job "$id2" add fixer "$ref" >/dev/null || fail "job add $ref"; done
limits 69 10 1
live_pid
night admit "$id2" f-mid claudeb "$LIVE" opus >/dev/null || fail "the Opus run was not admitted"
live_pid
night admit "$id2" f-mid2 claudeb "$LIVE" sonnet >/dev/null &
son_gate=$!
for i in $(seq 1 30); do kill -0 "$son_gate" 2>/dev/null || break; sleep 0.1; done
kill "$son_gate" 2>/dev/null
assert jqe '.admission.state == "admitted" and .admission.cost == 3.5' \
  <<<"$(jq -c '.jobs[] | select(.ref == "f-mid2")' "$NIGHTS/$id2.json")"
assert jqe '.admission.cost == 7' <<<"$(jq -c '.jobs[] | select(.ref == "f-mid")' "$NIGHTS/$id2.json")"

# The night's spend on walls: a run whose last attempt walled counts, one rescued after a wall does not.
mkdir -p "$WORKER_RUN_DIR/claudeb-1-1-a" "$WORKER_RUN_DIR/claudeb-1-1-b"
printf '2\n' >"$WORKER_RUN_DIR/claudeb-1-1-a/attempt"; : >"$WORKER_RUN_DIR/claudeb-1-1-a/wall-reset.2"
printf '2\n' >"$WORKER_RUN_DIR/claudeb-1-1-b/attempt"; : >"$WORKER_RUN_DIR/claudeb-1-1-b/wall-reset.1"
assert test "$(pyq 'import night_spend as n; print(n.ended_on_wall("claudeb-1-1-a"), n.ended_on_wall("claudeb-1-1-b"))')" = "True False"
assert test "$(pyq 'import night_spend as n, collections as c; print(n.walled_share({"kinds": {"fixers": c.Counter(a=300)}, "walled": 63}))')" = 21.0

# worker-run: a deferred job ends the run before its slot; a long wait re-picks a picked account, never a named one.
eval "$(sed -n '/^night_admit() {/,/^}/p' "$ROOT/share/worker-run-pool.sh")"
declare -F night_admit >/dev/null || fail "worker-run has no night_admit"
run="$WORK/run" && mkdir -p "$run"
printf '{"account": "old", "explicit_account": "", "resume": "", "model": "opus"}' >"$run/meta.json"
printf 'old · title\n' >"$run/tag"
meta_update() { local d=$1 f=$2; shift 2; jq "$@" "$f" "$d/meta.json" >"$d/m" && mv "$d/m" "$d/meta.json"; }
pick_account_listing() { PICKED_RC=0 PICKED_ACCOUNT=fresh; }
printf '#!/usr/bin/env bash\nprintf "%%s\\n" "$*" >>"%s"\nprintf "night %%s job deferred: P3\\n" "$2"\nexit 3\n' "$WORK/gate-args" >"$FAKE_BIN/gate"
chmod +x "$FAKE_BIN/gate"
rc=0; WORKER_RUN_NIGHT_RUN="$FAKE_BIN/gate" night_admit "$run" claudeb night/n1/job-a || rc=$?
assert test "$rc" -eq 1
assert grep -q "^admit n1 job-a claudeb $$ opus\$" "$WORK/gate-args"
assert grep -q 'deferred: P3' "$run/err"
printf '#!/usr/bin/env bash\nexit 0\n' >"$FAKE_BIN/gate"
WORKER_RUN_NIGHT_RUN="$FAKE_BIN/gate" WORKER_RUN_ADMIT_REPICK_S=0 night_admit "$run" claudeb night/n1/job-a || fail "an admitted run was stopped"
assert jqe '.account == "fresh"' "$run/meta.json"
assert grep -q '^fresh · title$' "$run/tag"
printf '{"account": "named", "explicit_account": "named", "resume": "", "model": "opus"}' >"$run/meta.json"
WORKER_RUN_NIGHT_RUN="$FAKE_BIN/gate" WORKER_RUN_ADMIT_REPICK_S=0 night_admit "$run" claudeb night/n1/job-a || fail "admitted"
assert jqe '.account == "named"' "$run/meta.json"

# A fixture Harness directory with no SYSTEM_DOCTOR_DIR never reads the live system doctor's latest.json.
assert [ "$(env -u SYSTEM_DOCTOR_DIR python3 -B -c "import sys; sys.path.insert(0, '$ROOT/share'); import night_priority as n; print(n.doctor_path('system'))")" = None ]
assert [ "$(pyq "import night_priority as n; print(n.doctor_path('system'))")" = "$WORK/system/latest.json" ]

echo "PASS: test_night_admission ($asserts asserts)"
