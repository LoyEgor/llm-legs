#!/usr/bin/env bash
. "${BASH_SOURCE%"${BASH_SOURCE##*/}"}lib/suite-journal.sh"
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
. "$ROOT/share/test-scope.sh"
WORK="$(mktemp -d)"
trap 'xargs kill 2>/dev/null <"$WORK/data/orchestrators"; rm -rf "$WORK"' EXIT
WORK="$(cd -P "$WORK" && pwd)"
asserts=0
exec 8>&2
# fd 8: an assertion run as `assert_fails cmd 2>file` would otherwise send its FAIL line into the file.
fail() { echo "FAIL: $*" >&8; exit 1; }
assert() { asserts=$((asserts + 1)); "$@" || fail "assert $asserts failed: $*"; }
assert_fails() {
  asserts=$((asserts + 1))
  "$@" && fail "assert $asserts unexpectedly succeeded: $*"
  return 0
}
jqe() { jq -e "$@" >/dev/null; }

HOME="$WORK/home"
FAKE_BIN="$WORK/bin"
DATA="$WORK/data"
OPENED="$WORK/opened"
NIGHTS="$WORK/doctors/nights"
export HOME DATA OPENED
unset WORDS_DIR WORDS_ROOT
export DOCTORS_DIR="$WORK/doctors" LLM_DOCTOR_DIR="$WORK/llm" HARNESS_DOCTOR_DIR="$WORK/harness" \
  UPDATER_DOCTOR_DIR="$WORK/updater" NIGHT_RUN_OPENER="$FAKE_BIN/opener" NIGHT_RUN_WORKER_PICK="$FAKE_BIN/worker-pick" \
  NIGHT_RUN_SWEEP_REPOS="$WORK/sweep-repos" NIGHT_RUN_REDEPLOY="$FAKE_BIN/redeploy"
PATH="$FAKE_BIN:/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin:/usr/local/bin"
mkdir -p "$FAKE_BIN" "$DATA" "$HOME" "$WORK/llm" "$WORK/harness" "$WORK/updater"
: >"$OPENED"
cat >"$FAKE_BIN/opener" <<'EOF'
#!/usr/bin/env bash
[ ! -e "$DATA/opener-fails" ] || exit 1
printf '%s\n' "$*" >>"$OPENED"
session=$(LC_ALL=C sed -n 's/.*--session-id \([^ ]*\) .*/\1/p' "$1")
bash -c 'exec -a "$0" sleep 600' "claudeb profile acct-n --session-id $session" >/dev/null 2>&1 &
printf '%s\n' "$!" >>"$DATA/orchestrators"
EOF
printf '#!/usr/bin/env bash\nprintf "%%s\\n" "$*" >>"$DATA/pick-args"\nprintf "acct-n\\n"\n' >"$FAKE_BIN/worker-pick"
printf '#!/usr/bin/env bash\nexit 0\n' >"$FAKE_BIN/claudeb"
printf '#!/usr/bin/env bash\necho redeploy >>"$DATA/redeploys"\nexit 1\n' >"$FAKE_BIN/redeploy"
cat >"$FAKE_BIN/review-bench" <<'EOF'
#!/usr/bin/env bash
[ "$1" != review ] || { printf '%s\n' "$*" >>"$DATA/price-args"
  case " $* " in *' --due '*) cat "$DATA/price-due" >&2 ;; *) cat "$DATA/price" >&2 ;; esac; exit 0; }
[ "$1 $3" = "fix --print" ] || exit 2
[ ! -e "$DATA/unreadable-$2" ] || { echo "no round $2" >&2; exit 1; }
[ ! -e "$DATA/open-$2" ] || cat "$DATA/open-$2"
EOF
chmod +x "$FAKE_BIN"/*

night() { bash "$ROOT/bin/night-run" "$@"; }
# The report under its comparison table, which a blank line closes.
body() { sed '1,/^$/d' "$@"; }
record() { printf '%s/%s.json' "$NIGHTS" "$1"; }
doc() { jq -n --argjson n "$2" --argjson p "${3:-[]}" '{contract: 1, problem_count: $n, problems: $p}' >"$WORK/$1/latest.json"; }
doc llm 5
doc harness 3 '[{"id": "h1", "state": "new"}, {"id": "h2", "state": "open"}, {"id": "h3", "state": "regressed"}, {"id": "h4", "state": "watch", "fact": "fine"}]'

# start: the record, the orchestrator chat on the main checkout with the sweep word, the session.
night start >"$WORK/out" || fail "start failed"
id=$(sed -n 's/^night \([0-9]\{8\}T[0-9]\{6\}Z-[0-9a-f]\{4\}\) started: orchestrator on acct-n$/\1/p' "$WORK/out")
assert [ -n "$id" ]
R=$(record "$id")
assert jqe 'keys == (["id", "started_at", "finished_at", "session", "account", "command", "note",
  "doctors_before", "doctors_after", "doctor_states_before", "doctor_states_after",
  "doctor_problems_before", "doctor_problems_after", "jobs"] | sort)' "$R"
assert jqe '.doctor_states_before == {llm: {proved: 0, pending: 0, open: 0, new: 0, regressed: 0},
  harness: {proved: 0, pending: 0, open: 1, new: 1, regressed: 1}, updater: null, code: null, system: null} and .doctor_states_after == null' "$R"
assert jqe '.doctor_problems_before == {llm: {}, harness: {h1: "new", h2: "open", h3: "regressed", h4: "watch"},
  updater: null, code: null, system: null} and .doctor_problems_after == null' "$R"
assert jqe '.doctors_before == {llm: 5, harness: 3, updater: null, code: null, system: null} and .doctors_after == null and .jobs == []
  and .finished_at == null and .account == "acct-n"' "$R"
session=$(jq -r .session "$R")
assert [ "${#session}" = 36 ]
assert [ "$(cat "$OPENED")" = "$NIGHTS/$id.command" ]
assert [ "$(cat "$DATA/redeploys")" = redeploy ]
assert jqe --arg c "$NIGHTS/$id.command" '.command == $c' "$R"
main=$(dirname "$(git -C "$ROOT" rev-parse --path-format=absolute --git-common-dir)")
assert grep -qF "cd $main " "$NIGHTS/$id.command"
assert grep -qF -- "--session-id $session " "$NIGHTS/$id.command"
exec_line=$(grep '^exec ' "$NIGHTS/$id.command")
eval "set -- ${exec_line#exec }"
assert [ "${!#}" = "сделай чистку — night run $id" ]
assert [ "$1 $2 $3 $4" = "caffeinate -i env CLAUDE_CODE_MAX_CONCURRENT_SUBAGENTS=200" ]
assert grep -qxF -- '--account claudeb --role chat --model opus --claim' "$DATA/pick-args"

# A night whose orchestrator chat runs refuses a second start, however long it runs; no deadline flag.
assert_fails night start 2>"$WORK/err"
assert grep -qF "night $id is still running" "$WORK/err"
# The refusal names the live chat and never sends the caller to finish a running night.
assert grep -qF "its orchestrator chat $session has run since $(jq -r .started_at "$R")" "$WORK/err"
assert_fails grep -qF 'night-run finish' "$WORK/err"
assert_fails night start --deadline-h 2 2>/dev/null
assert [ "$(wc -l <"$OPENED" | tr -d ' ')" = 1 ]

# Jobs: add before dispatch, one per ref, kinds checked.
night job "$id" add fixer llm-20260930T010203Z --branch "night/$id/llm-20260930T010203Z" >/dev/null || fail "job add"
night job "$id" add vendor codex-e1 --branch "night/$id/codex" >/dev/null || fail "job add vendor"
night job "$id" add debt debt-round >/dev/null || fail "job add debt"
night job "$id" add fixer harness-r1 --branch "night/$id/harness-r1" >/dev/null || fail "job add harness"
assert_fails night job "$id" add fixer harness-r1 2>"$WORK/err"
assert grep -qF 'already has job harness-r1' "$WORK/err"
assert_fails night job "$id" add robot x 2>/dev/null
assert_fails night job nosuch add fixer x 2>/dev/null
assert jqe '[.jobs[] | .state] == ["pending", "pending", "pending", "pending"]
  and .jobs[0] == {kind: "fixer", ref: "llm-20260930T010203Z", state: "pending", reason: null,
    branch: "night/'"$id"'/llm-20260930T010203Z", review: null, commits: [], pushed: false}
  and .jobs[2].branch == null' "$R"

# Parallel writers never drop each other's jobs.
for n in 1 2 3 4 5 6 7 8; do night job "$id" add debt "p$n" >/dev/null & done
wait
assert jqe '[.jobs[] | select(.ref | startswith("p"))] | length == 8' "$R"
assert [ ! -d "$NIGHTS/.lock" ]
# The nights lock is the shared store lock: a dead holder's is broken at once, a live holder's is never taken.
bash -c 'exit 0' & dead=$!
wait "$dead"
mkdir "$NIGHTS/.lock" && printf '%s\n' "$dead" >"$NIGHTS/.lock/pid"
LLM_STORE_LOCK_DELAY=0.01 LLM_STORE_LOCK_RETRIES=40 night job "$id" set p8 state=pending >/dev/null ||
  fail "a lock left by a dead holder blocked the job"
assert [ ! -d "$NIGHTS/.lock" ]
sleep 30 & live=$!
mkdir "$NIGHTS/.lock" && printf '%s\n' "$live" >"$NIGHTS/.lock/pid"
touch -t "$(date -v-2M +%Y%m%d%H%M.%S)" "$NIGHTS/.lock"
assert_fails env LLM_STORE_LOCK_DELAY=0.01 LLM_STORE_LOCK_RETRIES=40 bash "$ROOT/bin/night-run" job "$id" add debt live-holder 2>"$WORK/err"
assert grep -qF 'nights lock' "$WORK/err"
assert [ "$(cat "$NIGHTS/.lock/pid")" = "$live" ]
kill "$live" 2>/dev/null
rm -rf "$NIGHTS/.lock"

# set: states and their checks.
assert_fails night job "$id" set debt-round state=done 2>/dev/null
assert_fails night job "$id" set debt-round state=left 2>"$WORK/err"
assert grep -qF 'needs reason=' "$WORK/err"
assert_fails night job "$id" set debt-round colour=red 2>/dev/null
assert_fails night job "$id" set nosuch state=merged 2>/dev/null
assert_fails night job "$id" set debt-round commits=llm-legs 2>/dev/null
night job "$id" set debt-round state=left "reason=hung: idle 1800" >/dev/null || fail "set left"
night job "$id" set harness-r1 state=failed-launch reason=opener >/dev/null || fail "set failed"
assert jqe '.jobs[2].state == "left" and .jobs[2].reason == "hung: idle 1800"' "$R"

# pushed=true is checked against the remote: on origin's main, and made after the night's base.
git init -q --bare "$WORK/origin.git"
git init -q -b main "$WORK/repo"
git -C "$WORK/repo" -c user.name=t -c user.email=t@t commit -q --allow-empty -m zero
based_hash=$(git -C "$WORK/repo" rev-parse HEAD)
git -C "$WORK/repo" update-ref "refs/night/$id/base" "$based_hash"
git -C "$WORK/repo" -c user.name=t -c user.email=t@t commit -q --allow-empty -m one
git -C "$WORK/repo" remote add origin "$WORK/origin.git"
git -C "$WORK/repo" push -q origin main
pushed_hash=$(git -C "$WORK/repo" rev-parse HEAD)
side_tree=$(printf '100644 blob %s\tside\n' "$(printf 'side\n' | git -C "$WORK/repo" hash-object -w --stdin)" | git -C "$WORK/repo" mktree)
side_hash=$(git -C "$WORK/repo" -c user.name=t -c user.email=t@t commit-tree "$side_tree" -p HEAD -m side)
git -C "$WORK/repo" push -q origin "$side_hash:refs/heads/side"
git -C "$WORK/repo" -c user.name=t -c user.email=t@t commit -q --allow-empty -m two
local_hash=$(git -C "$WORK/repo" rev-parse HEAD)
printf '%s\n' "$WORK/elsewhere/llm-legs" "$WORK/repo" >"$WORK/sweep-repos"
assert_fails night job "$id" set llm-20260930T010203Z pushed=true 2>"$WORK/err"
assert grep -qF 'needs the job' "$WORK/err"
night job "$id" set llm-20260930T010203Z state=merged "commits=repo:$local_hash" review=rb-1 >/dev/null || fail "set merged"
# A job merges only once its review round is settled: fixed through its brief or closed nofix.
printf 'ROUND: rb-open\n\n  0  P2  a.txt  defect\n' >"$DATA/open-rb-open"
: >"$DATA/unreadable-rb-gone"
assert_fails night job "$id" set p7 state=merged review=rb-open 2>"$WORK/err"
assert grep -qF "job p7 cannot be merged while its review round rb-open has open findings" "$WORK/err"
assert grep -qF "review-bench close rb-open --nofix" "$WORK/err"
night job "$id" set p7 review=rb-open >/dev/null || fail "a pending job records its open round"
assert_fails night job "$id" set p7 state=merged 2>"$WORK/err"
assert grep -qF "review round rb-open has open findings" "$WORK/err"
assert_fails night job "$id" set p7 state=merged review=rb-gone 2>"$WORK/err"
assert grep -qF "job p7: review round rb-gone cannot be read: no round rb-gone" "$WORK/err"
assert jqe '[.jobs[] | select(.ref == "p7")][0] | .state == "pending" and .review == "rb-open"' "$R"
night job "$id" set p7 review= >/dev/null || fail "clear review"
# A Code fixer job lands only through code-doctor check on its run record; suites=passed attests green suites.
cat >"$FAKE_BIN/code-doctor" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$DATA/code-checks"
case " $* " in *" --suites-passed "*) exit 0 ;; esac
echo "alpha/bin/x: deletion proof: green suites not confirmed (--suites-passed)"
exit 1
EOF
chmod +x "$FAKE_BIN/code-doctor"
export NIGHT_RUN_CODE_DOCTOR="$FAKE_BIN/code-doctor"
jq '.id = "ncode" | .started_at = "2020-01-01T00:00:00Z" | .jobs = []' "$R" >"$NIGHTS/ncode.json"
cref=code-code-20261001T020700Z-0b0b
night job ncode add fixer "$cref" >/dev/null || fail "add the code job"
assert_fails night job ncode set "$cref" state=merged 2>"$WORK/err"
assert grep -qF "job $cref: no doctor-fix run record" "$WORK/err"
mkdir -p "$DOCTORS_DIR/runs"
printf '{"id": "%s", "doctor": "code"}\n' "$cref" >"$DOCTORS_DIR/runs/$cref.json"
assert_fails night job ncode set "$cref" state=merged 2>"$WORK/err"
assert grep -qF "green suites not confirmed" "$WORK/err"
assert grep -qxF "check $DOCTORS_DIR/runs/$cref.json --base refs/night/ncode/base --landing" "$DATA/code-checks"
night job ncode set "$cref" state=merged suites=passed >/dev/null || fail "a code job with its suites passed lands"
assert jqe --arg r "$cref" '[.jobs[] | select(.ref == $r)][0] | .state == "merged" and .suites == "passed"' "$NIGHTS/ncode.json"
# Each code-doctor check is a timed repository validation, a refused one included; the suite pass and the
# landing follow the passing one.
assert jqe --arg r "$cref" '[.events[] | select(.job == $r) | [.phase, .check, .ok]]
  == [["add", null, null], ["validate", "code", false], ["validate", "code", false], ["validate", "code", true], ["suites", null, null], ["landing", null, null]]
  and (.events | all(.secs == null or (.secs | type) == "number"))' "$NIGHTS/ncode.json"
assert_fails night job ncode set "$cref" suites=green 2>/dev/null
lref="leftover-night-n0-$cref"
printf '{"id": "%s", "doctor": "code", "night": "n0"}\n' "$cref" >"$DOCTORS_DIR/runs/$cref.json"
jq --arg r "$lref" --arg b "night/n0/$cref" '.jobs += [{kind: "leftover", ref: $r, state: "pending", reason: null, branch: null,
  review: null, commits: [], pushed: false, adopted: [{repo: "/x", branch: $b}]}]' "$NIGHTS/ncode.json" >"$WORK/tmp" &&
  mv "$WORK/tmp" "$NIGHTS/ncode.json"
assert_fails night job ncode set "$lref" state=merged 2>"$WORK/err"
assert grep -qF "job $cref cannot land, code-doctor check refuses" "$WORK/err"
assert grep -qxF "check $DOCTORS_DIR/runs/$cref.json --base refs/night/n0/base --landing" "$DATA/code-checks"
rm "$NIGHTS/ncode.json"
assert_fails night job "$id" set llm-20260930T010203Z pushed=true 2>"$WORK/err"
assert grep -qF "commit $local_hash is not on origin" "$WORK/err"
assert_fails night job "$id" set llm-20260930T010203Z "commits=repo:$side_hash" pushed=true 2>"$WORK/err"
assert grep -qF "commit $side_hash is not on origin main" "$WORK/err"
assert_fails night job "$id" set llm-20260930T010203Z "commits=repo:$based_hash" pushed=true 2>"$WORK/err"
assert grep -qF "commit $based_hash is already in refs/night/$id/base" "$WORK/err"
# The origin check runs before the nights lock is taken: a held lock never waits on the network.
sleep 30 & live=$!
mkdir "$NIGHTS/.lock" && printf '%s\n' "$live" >"$NIGHTS/.lock/pid"
assert_fails env LLM_STORE_LOCK_DELAY=0.01 LLM_STORE_LOCK_RETRIES=40 bash "$ROOT/bin/night-run" job "$id" set llm-20260930T010203Z pushed=true 2>"$WORK/err"
assert grep -qF "commit $local_hash is not on origin" "$WORK/err"
kill "$live" 2>/dev/null
rm -rf "$NIGHTS/.lock"
assert jqe '.jobs[0].pushed == false and .jobs[0].commits == [{repo: "repo", hash: "'"$local_hash"'"}]
  and .jobs[0].review == "rb-1"' "$R"
assert_fails night job "$id" set llm-20260930T010203Z "commits=nowhere:$pushed_hash" pushed=true 2>"$WORK/err"
assert grep -qF 'no repository nowhere' "$WORK/err"
# origin moved on from a checkout this repository never fetched: its head is fetched before the ancestry check.
git clone -q -b main "$WORK/origin.git" "$WORK/other"
git -C "$WORK/other" -c user.name=t -c user.email=t@t commit -q --allow-empty -m later
git -C "$WORK/other" push -q origin HEAD:main
night job "$id" set llm-20260930T010203Z "commits=repo:$pushed_hash" pushed=true >/dev/null || fail "pushed by name"
night job "$id" set codex-e1 state=merged "commits=$WORK/repo:$pushed_hash" pushed=true >/dev/null || fail "pushed by path"
assert jqe '.jobs[0].pushed == true and .jobs[1].pushed == true' "$R"
# A new commit list is unverified: pushed goes back to false until pushed=true checks it; the same list keeps it.
night job "$id" set llm-20260930T010203Z "commits=repo:$pushed_hash" >/dev/null || fail "same commits"
assert jqe '.jobs[0].pushed == true' "$R"
night job "$id" set llm-20260930T010203Z "commits=repo:$local_hash" >"$WORK/out" || fail "new commits"
assert jqe '.jobs[0].pushed == false' "$R"
assert grep -qxF "night $id: job llm-20260930T010203Z merged" "$WORK/out"
night job "$id" set llm-20260930T010203Z "commits=repo:$pushed_hash" pushed=true >/dev/null || fail "pushed again"
assert_fails night job "$id" set p1 state=blocked-on-egor 2>"$WORK/err"
assert grep -qF 'state blocked-on-egor needs reason=' "$WORK/err"
night job "$id" set p1 state=blocked-on-egor reason="step 10 needs his word" >/dev/null || fail "set blocked"

# Menu and report while running.
# Plain words for the Doctors menu: a title line, then one line per job; red only where Egor is needed.
night latest --menu >"$WORK/menu"
started=$(jq -r '.started_at | fromdateiso8601 | strflocaltime("%H:%M")' "$R")
assert [ "$(head -1 "$WORK/menu")" = "$(printf 'Night run since %s: 2 of 12 · 1 unfinished · 7 in progress · 1 failed to launch · 1 need you\t1\t1\t%s' "$started" "$id")" ]
assert grep -qxF "$(printf 'LLM fixer\t0\t\tllm-20260930T010203Z\tfixer\t0')" "$WORK/menu"
assert grep -qxF "$(printf 'cleanup debt-round · unfinished · hung\t2\thung: idle 1800\tdebt-round\tdebt\t0')" "$WORK/menu"
assert grep -qxF "$(printf 'harness-r1 · failed to launch · opener\t1\topener\tharness-r1\tfixer\t0')" "$WORK/menu"
assert grep -qxF "$(printf 'cleanup p1 · needs you · step 10 needs his word\t1\tstep 10 needs his word\tp1\tdebt\t0')" "$WORK/menu"
assert grep -qxF "$(printf 'cleanup p2 · in progress\t2\t\tp2\tdebt\t0')" "$WORK/menu"
assert [ -z "$(cut -f5 "$WORK/menu" | grep -x doctor)" ]
assert [ "$(wc -l <"$WORK/menu" | tr -d ' ')" = 13 ]

# finish: doctors after, pending becomes left with a reason; a second finish refuses.
doc llm 1
doc harness 0 '[{"id": "c1", "state": "fixed-pending", "fact": "fixed · 25 events since · 0 matched · a fix"},
  {"id": "c2", "state": "fixed-pending", "fact": "unproven · 3 events since · 0 matched, needs 20 events and none matched · b"},
  {"id": "c3", "state": "fixed-pending", "fact": "fixed · 30 events since · 2 matched · c"}, {"id": "c4", "state": "new"}, {"id": "c5", "state": "new"}]'
doc updater 2 '[{"id": "u1", "state": "watch", "rule": "fix-proof", "fact": "W1 · fixed 0d · 0 since · 0 matched · unproven"}]'

night finish "$id" >/dev/null || fail "finish"
assert [ "$(wc -l <"$DATA/redeploys" | tr -d ' ')" = 2 ]
assert_fails night finish "$id" 2>/dev/null
assert jqe '.doctors_after == {llm: 1, harness: 0, updater: 2, code: null, system: null} and .finished_at != null
  and ([.jobs[] | select(.state == "pending")] | length) == 0
  and ([.jobs[] | select(.ref == "p2")][0] | .state == "left" and .reason == "no outcome recorded by the close")' "$R"
assert jqe '.doctor_problems_after == {llm: {}, harness: {c1: "proved", c2: "pending", c3: "pending", c4: "new", c5: "new"},
  updater: {u1: "pending"}, code: null, system: null}' "$R"
mkdir -p "$DOCTORS_DIR/runs"
printf '{"decisions": [{"id": "load:busy", "component": "unverified"}, {"id": "R1"}, {"id": "reading-miss:x", "component": "unverified"}]}\n' \
  >"$DOCTORS_DIR/runs/llm-20260930T010203Z.json"
printf '{"decisions": [{"id": "R2"}]}\n' >"$DOCTORS_DIR/runs/harness-r1.json"
night report "$id" >"$WORK/report" || fail "report"
assert grep -qxF "unverified component · llm-20260930T010203Z · load:busy, reading-miss:x" "$WORK/report"
assert [ "$(grep -c '^unverified' "$WORK/report")" = 1 ]
assert grep -qxF "llm 5 → 1 · proved 0 · pending 0 · new 0 · regressed 0" "$WORK/report"
assert grep -qxF "harness 3 → 0 · proved 1 · pending 2 · new 2 · regressed 0" "$WORK/report"
assert grep -qxF "updater - → 2 · proved 0 · pending 1 · new 0 · regressed 0" "$WORK/report"
assert grep -qxF "code - → -" "$WORK/report"
assert grep -qxF "system - → -" "$WORK/report"
assert [ -z "$(night latest --menu | grep -F 'harness 3 →')" ]
assert grep -qxF "landed · fixer · llm-20260930T010203Z · review rb-1 · repo@${pushed_hash:0:7} · code +0/-0" "$WORK/report"
assert grep -qxF "left · debt · debt-round · hung: idle 1800" "$WORK/report"
assert grep -qxF "failed-launch · fixer · harness-r1 · night/$id/harness-r1 · opener" "$WORK/report"
assert grep -qxF "total · 2 landed · 8 left · 1 failed-launch · 1 blocked-on-egor" "$WORK/report"
assert grep -qE "^blocked-on-egor · debt · p1( · [^ ]+)* · step 10 needs his word$" "$WORK/report"
assert [ "$(body "$WORK/report" | grep -vcE '^(ledger|trend|roi) · ')" = 28 ]
assert [ "$(grep -m1 -E '^(ledger|trend) · ' "$WORK/report")" = "ledger · night $id · $(jq -r '((.finished_at | fromdate)
  - (.started_at | fromdate)) / 3600 * 10 | round / 10 | tostring | if test("\\.") then . else . + ".0" end' "$R") h" ]
assert grep -qxE "trend · problems [0-9]+ → [0-9]+ over [0-9]+ nights · (moving forward|treading water|going back)" "$WORK/report"
assert [ "$(body "$WORK/report" | sed -n 2p)" = "jobs · landed 2 (fixer 1, vendor 1) · left 8 (debt 8) · other 2 (debt 1, fixer 1)" ]
assert [ "$(body "$WORK/report" | sed -n 9p | cut -d' ' -f1-2)" = "night $id" ]
assert [ "$(awk '{ print length }' "$WORK/report" | sort -n | tail -1)" -le 100 ]
assert cmp -s "$WORK/report" <(night report)

# Phase events: appended in order, numbered by position, stamped, each job event chained to that
# job's previous one; job add and set leave one each, and the job objects stay as they were.
assert jqe '[.events[].id] == [range(1; (.events | length) + 1)]
  and (.events | all(.at | test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$")))
  and .events[0] == {id: 1, at: .events[0].at, phase: "add", job: "llm-20260930T010203Z", pred: [], kind: "fixer"}
  and ([.events[] | select(.phase == "add") | .job] == [.jobs[].ref])
  and (.events as $e | [range(0; $e | length) as $i | $e[$i] | select(.job != null)
    | .pred == ([$e[:$i][] | select(.job == $e[$i].job) | .id] | .[-1:])] | all)
  and (.jobs | all(has("added_at") or has("events") | not))' "$R"
assert jqe '[.events[] | select(.job == "llm-20260930T010203Z") | [.phase, .check, .ok]][0:5]
  == [["add", null, null], ["validate", "review", true], ["landing", null, null], ["set", null, null], ["validate", "push", false]]
  and ([.events[] | select(.job == "llm-20260930T010203Z" and .phase == "set")][0].keys == ["commits", "pushed", "review"])' "$R"
assert jqe 'any(.events[]; .job == "p7" and .phase == "validate" and .check == "review" and .ok == false)
  and any(.events[]; .job == "p1" and .phase == "owner-pause")
  and any(.events[]; .job == "debt-round" and .phase == "state" and .state == "left")' "$R"
# A refusal behind a held lock is not recorded: it never waits for the lock.
assert jqe '[.events[] | select(.job == "llm-20260930T010203Z" and .phase == "validate" and .check == "push") | .ok]
  == [false, false, false, true, true]' "$R"
# The close follows every job's last event; the branch pruning after it is timed.
assert jqe '.events[-2].phase == "finish" and .events[-1].phase == "prune" and .events[-1].pred == [.events[-2].id]
  and (.events[-1].secs | type) == "number"
  and .events[-2].pred == ([.events[:-2][] | select(.job != null)] | group_by(.job) | map(last.id) | sort)' "$R"
# Leaving an owner pause is a phase of its own.
night job "$id" set p1 state=nothing-to-do >/dev/null || fail "resume p1"
assert jqe '[.events[] | select(.job == "p1") | .phase][-2:] == ["owner-resume", "state"]' "$R"
jq '.started_at = "2026-01-01T00:00:00Z"' "$R" >"$WORK/tmp" && mv "$WORK/tmp" "$R"

# A clean night reads green; a merged job not pushed turns it red.
night start >"$WORK/out" || fail "second start"
id2=$(sed -n 's/^night \([^ ]*\) started:.*/\1/p' "$WORK/out")
night job "$id2" add fixer f1 >/dev/null
night job "$id2" add vendor v1 >/dev/null
assert_fails night job "$id2" set f1 state=merged "commits=repo:$pushed_hash" pushed=true 2>"$WORK/err"
assert grep -qF "has no refs/night/$id2/base" "$WORK/err"
git -C "$WORK/repo" update-ref "refs/night/$id2/base" "$based_hash"
night job "$id2" set f1 state=merged "commits=repo:$pushed_hash" pushed=true >/dev/null
night job "$id2" set v1 state=nothing-to-do >/dev/null
night finish "$id2" >/dev/null
day2=$(jq -r '.started_at | fromdateiso8601 | strflocaltime("%d %b") | ltrimstr("0")' "$(record "$id2")")
assert [ "$(night latest --menu | head -1)" = "$(printf 'Last night %s: 2 of 2\t0\t0\t%s' "$day2" "$id2")" ]
night report | body | sed -n 9p | grep -q "^night $id2 " || fail "report without an id reads the latest night"
night job "$id2" set v1 state=merged "commits=repo:$local_hash" >/dev/null
assert [ "$(night latest --menu | head -1)" = "$(printf 'Last night %s: 2 of 2 · 1 not pushed\t2\t0\t%s' "$day2" "$id2")" ]
assert grep -qxF "$(printf 'v1 update · not pushed\t2\t\tv1\tvendor\t0')" <(night latest --menu)
assert grep -qxF "landed · vendor · v1 · repo@${local_hash:0:7} · code +0/-0 · not pushed" <(night report)
assert grep -qxF "total · 2 landed · 1 not pushed" <(night report)
night job "$id2" set f1 state=nothing-to-do >/dev/null
night job "$id2" set v1 state=nothing-to-do >/dev/null
assert [ "$(night latest --menu | head -1)" = "$(printf 'Last night %s: 2 of 2\t0\t0\t%s' "$day2" "$id2")" ]

# Per job the code lines its commits add and remove, test paths left out, summed over its commits.
mkdir -p "$WORK/repo/bin" "$WORK/repo/tests" "$WORK/repo/tools"
printf 'a\nb\nc\n' >"$WORK/repo/bin/x"
printf '1\n2\n3\n4\n5\n' >"$WORK/repo/tests/test_x.sh"
printf 'p\nq\n' >"$WORK/repo/tools/test_y.py"
git -C "$WORK/repo" add -A && git -C "$WORK/repo" -c user.name=t -c user.email=t@t commit -q -m code
code1=$(git -C "$WORK/repo" rev-parse HEAD)
printf 'a\nB\nc\n' >"$WORK/repo/bin/x"
printf '1\n' >"$WORK/repo/tests/test_x.sh"
git -C "$WORK/repo" -c user.name=t -c user.email=t@t commit -q -am more
code2=$(git -C "$WORK/repo" rev-parse HEAD)
night job "$id2" add fixer c1 >/dev/null
night job "$id2" set c1 "commits=repo:$code1,repo:$code2" >/dev/null
night job "$id2" add fixer c2 >/dev/null
night job "$id2" set c2 "commits=repo:$code1,repo:0000000000000000000000000000000000000000" >/dev/null
night job "$id2" add fixer c3 >/dev/null
night report "$id2" >"$WORK/report"
assert grep -qxF "pending · fixer · c1 · repo@${code1:0:7} · repo@${code2:0:7} · code +4/-1" "$WORK/report"
assert grep -qxF "pending · fixer · c2 · repo@${code1:0:7} · repo@0000000 · code ?" "$WORK/report"
assert grep -qxF "nothing-to-do · fixer · f1 · repo@${pushed_hash:0:7} · code +0/-0" "$WORK/report"
assert grep -qxF "pending · fixer · c3" "$WORK/report"

# A night whose orchestrator chat is gone and never finished no longer blocks start, and reads red.
night start >"$WORK/out" || fail "third start"
id3=$(sed -n 's/^night \([^ ]*\) started:.*/\1/p' "$WORK/out")
assert_fails night start 2>/dev/null
pkill -f -- "--session-id $(jq -r .session "$(record "$id3")")"
while pgrep -f -- "--session-id $(jq -r .session "$(record "$id3")")" >/dev/null; do sleep 0.1; done
night start >"$WORK/out" || fail "start after the orchestrator chat ended"
id4=$(sed -n 's/^night \([^ ]*\) started:.*/\1/p' "$WORK/out")
assert [ "$(night report "$id3" | body | sed -n 9p)" = "night $id3 · $(jq -r '.started_at | fromdateiso8601 | strflocaltime("%H:%M")' "$(record "$id3")")–- · UNFINISHED" ]
rm "$(record "$id")" "$(record "$id2")" "$(record "$id4")"
IFS=$'\t' read -r text red running _ < <(night latest --menu)
assert [ "$text" = "Last night $(jq -r '.started_at | fromdateiso8601 | strflocaltime("%d %b") | ltrimstr("0")' "$(record "$id3")"), stopped early: no jobs" ]
assert [ "$red$running" = 00 ]

# The chat does not open: the night is closed with a note and reads red.
rm "$(record "$id3")"
touch "$DATA/opener-fails"
assert_fails night start 2>"$WORK/err"
assert grep -qF 'the orchestrator chat did not open' "$WORK/err"
id5=$(ls "$NIGHTS" | sed -n 's/\.json$//p' | head -1)
assert jqe '.finished_at != null and (.note | startswith("orchestrator chat did not open"))' "$(record "$id5")"
IFS=$'\t' read -r text red _ < <(night latest --menu)
assert [ "$text" = "Last night $(jq -r '.started_at | fromdateiso8601 | strflocaltime("%d %b") | ltrimstr("0")' "$(record "$id5")"): did not start" ]
assert [ "$red" = 1 ]
assert grep -q "^orchestrator chat did not open	1	orchestrator chat did not open: " <(night latest --menu)
rm "$DATA/opener-fails"
night start >/dev/null || fail "a failed open does not block the next start"

# base: every sweep repository is snapshotted as it stands (uncommitted and untracked included)
# into refs/night/<id>/base, without touching its index or working tree. Untracked secret names and
# blobs over 5 MB stay out of the base, each named.
git init -q -b main "$WORK/snap"
git -C "$WORK/snap" -c user.email=t@t -c user.name=t commit -q --allow-empty -m root
printf 'committed\n' >"$WORK/snap/a"
printf 'cert\n' >"$WORK/snap/c.pem"
git -C "$WORK/snap" add a c.pem
git -C "$WORK/snap" -c user.email=t@t -c user.name=t commit -q -m a
printf 'dirty\n' >"$WORK/snap/a"
printf 'cert2\n' >"$WORK/snap/c.pem"
printf 'new\n' >"$WORK/snap/untracked"
mkdir -p "$WORK/snap/keys"
printf 'SECRET=1\n' >"$WORK/snap/.env"
printf 'pem\n' >"$WORK/snap/keys/server.pem"
printf 'key\n' >"$WORK/snap/k.key"
printf 'ssh\n' >"$WORK/snap/keys/id_ed25519"
head -c 6291456 /dev/zero >"$WORK/snap/big.bin"
printf '%s\n' "$WORK/snap" >"$WORK/sweep-repos"
id6=$(ls -t "$NIGHTS" | sed -n 's/\.json$//p' | head -1)
before_status=$(git -C "$WORK/snap" status --porcelain)
night base "$id6" >"$WORK/base.out" 2>"$WORK/base.err" || fail "night base failed"
assert [ "$(git -C "$WORK/snap" show "refs/night/$id6/base:a")" = dirty ]
assert [ "$(git -C "$WORK/snap" show "refs/night/$id6/base:c.pem")" = cert2 ]
assert [ "$(git -C "$WORK/snap" show "refs/night/$id6/base:untracked")" = new ]
for dropped in .env keys/server.pem k.key keys/id_ed25519 big.bin; do
  assert_fails git -C "$WORK/snap" cat-file -e "refs/night/$id6/base:$dropped" 2>/dev/null
  assert grep -qF "the base of $WORK/snap drops $dropped: " "$WORK/base.err"
done
assert grep -qxF "night-run: the base of $WORK/snap drops big.bin: a 6 MB blob" "$WORK/base.err"
assert [ "$(wc -l <"$WORK/base.err" | tr -d ' ')" = 5 ]
assert [ "$(git -C "$WORK/snap" rev-parse "refs/night/$id6/base^")" = "$(git -C "$WORK/snap" rev-parse HEAD)" ]
assert [ "$(git -C "$WORK/snap" status --porcelain)" = "$before_status" ]
assert jqe --arg c "$(git -C "$WORK/snap" rev-parse "refs/night/$id6/base")" '.bases.snap == $c' "$(record "$id6")"
assert jqe '.events[-1] | .phase == "base" and .repos == 1 and .pred == [] and .job == null and (.secs | type) == "number"' \
  "$(record "$id6")"
night finish "$id6" >/dev/null

# Resume: the SAME night reopens under a new orchestrator for its unfinished jobs, the old session kept
# in previous_sessions; the review-flow gate reads finished_at null and the new session's live process.
stop_chat() { pkill -f -- "--session-id $1"; while pgrep -f -- "--session-id $1" >/dev/null; do sleep 0.1; done; }
last_arg() { local line; line=$(grep '^exec ' "$NIGHTS/$1.command"); eval "set -- ${line#exec }"; printf '%s\n' "${!#}"; }
R6=$(record "$id6")
rm "$(record "$id5")"
night job "$id6" add vendor codex-e1 --branch "night/$id6/codex" >/dev/null
night job "$id6" set codex-e1 state=left 'reason=hung: idle 1800, branch night/x/codex' >/dev/null
night job "$id6" add fixer f-done >/dev/null
night job "$id6" set f-done state=nothing-to-do >/dev/null
night job "$id6" add debt debt >/dev/null
night job "$id6" set debt state=left reason=hung >/dev/null
assert grep -qxF "$(printf 'codex update · unfinished · hung\t2\thung: idle 1800, branch night/x/codex\tcodex-e1\tvendor\t1')" <(night latest --menu)
assert grep -qxF "$(printf 'f-done · nothing to do\t0\t\tf-done\tfixer\t0')" <(night latest --menu)
assert [ "$(night latest --menu | head -1 | cut -f4)" = "$id6" ]
old_session=$(jq -r .session "$R6")
assert_fails night start --job codex-e1 2>/dev/null
assert_fails night start --resume nosuch 2>/dev/null
assert_fails night start --resume "$id6" --job f-done 2>"$WORK/err"
assert grep -qF "night $id6 has no unfinished job f-done" "$WORK/err"
night start --resume "$id6" --job codex-e1 >"$WORK/out" || fail "resume one job"
assert [ "$(cat "$WORK/out")" = "night $id6 resumed: orchestrator on acct-n" ]
new_session=$(jq -r .session "$R6")
assert jqe --arg o "$old_session" '.finished_at == null and .doctors_after == null and .previous_sessions == [$o]
  and .session != $o and ([.jobs[] | [.ref, .state]] == [["codex-e1", "pending"], ["f-done", "nothing-to-do"], ["debt", "left"]])
  and .jobs[0].reason == "hung: idle 1800, branch night/x/codex"' "$R6"
assert pgrep -f -- "--session-id $new_session" >/dev/null
assert [ "$(last_arg "$id6")" = "сделай чистку — night run $id6 resume" ]
assert_fails night start --resume "$id6" 2>"$WORK/err"
assert grep -qF "night $id6 is still running" "$WORK/err"
assert_fails night start --cleanup 2>/dev/null
assert [ "$(night latest --menu | head -1 | cut -f3)" = 1 ]
assert grep -q "^codex update · in progress · hung	2	.*	codex-e1	vendor	0$" <(night latest --menu)
stop_chat "$new_session"
night start --resume "$id6" >/dev/null || fail "resume every unfinished job"
assert jqe --arg o "$old_session" --arg n "$new_session" '.previous_sessions == [$o, $n]
  and ([.jobs[] | [.ref, .kind, .state]] == [["codex-e1", "vendor", "pending"], ["f-done", "fixer", "nothing-to-do"],
    ["debt", "debt", "pending"]])' "$R6"
assert jqe '[.events[] | select(.phase == "resume")] | length == 2 and .[0].scope == "codex-e1" and (.[1] | has("scope") | not)
  and (.[1].pred | length) == 1' "$R6"
stop_chat "$(jq -r .session "$R6")"
night finish "$id6" >/dev/null
night job "$id6" set debt state=nothing-to-do >/dev/null
night start --resume "$id6" >/dev/null || fail "resume adds the cleanup a done one no longer covers"
assert jqe '[.jobs[] | select(.kind == "debt") | [.ref, .state]] == [["debt", "nothing-to-do"], ["debt-2", "pending"]]' "$R6"
assert grep -q "^cleanup · in progress	2		debt-2	debt	0$" <(night latest --menu)
stop_chat "$(jq -r .session "$R6")"
touch "$DATA/opener-fails"
assert_fails night start --resume "$id6" 2>/dev/null
assert jqe '.finished_at != null and (.note | startswith("orchestrator chat did not open")) and (.previous_sessions | length) == 4' "$R6"
assert jqe '([.jobs[] | select(.state == "pending")] == []) and (.jobs[] | select(.ref == "debt-2")
  | .state == "left" and (.reason | startswith("orchestrator chat did not open")))' "$R6"
rm "$DATA/opener-fails"

# Wall: an orchestrator stopped by a usage wall (StopFailure error rate_limit) has its chat ended and
# the night resumed on an account worker-pick gives room on (2026-10-06: the orchestrator on notcom
# hit its five-hour wall at 10:39 and the night stood still until someone typed).
night start --resume "$id6" >/dev/null || fail "resume for the wall cases"
walled=$(jq -r .session "$R6")
wall() { printf '{"session_id": "%s", "error": "%s"}' "$1" "$2" | NIGHT_RUN_WALL_SYNC=1 NIGHT_RUN_WALL_POLL=1 night wall; }
mkdir -p "$HOME/.claude/hooks/lib"
printf 'printf "%%s\\n" "${0##*/}${1:+ $1}" >>"%s/hook-time-keys"\n' "$WORK" >"$HOME/.claude/hooks/lib/hook-time.sh"
wall "$walled" overloaded >"$WORK/out" || fail "a stop that is no wall failed"
assert [ "$(cat "$WORK/hook-time-keys")" = "night-run wall" ]
rm "$HOME/.claude/hooks/lib/hook-time.sh"
wall not-an-orchestrator rate_limit >>"$WORK/out" || fail "a wall outside every night failed"
assert [ ! -s "$WORK/out" ]
assert [ "$(jq -r .session "$R6")" = "$walled" ]
assert pgrep -f -- "--session-id $walled" >/dev/null
: >"$DATA/pick-args"
wall "$walled" rate_limit >"$WORK/out" || fail "the wall failover failed"
assert [ "$(cat "$WORK/out")" = "night $id6 resumed: orchestrator on acct-n" ]
assert_fails pgrep -f -- "--session-id $walled"
assert grep -qxF -- '--account claudeb --role chat --model opus' "$DATA/pick-args"
assert jqe --arg w "$walled" '.session != $w and .previous_sessions[-1] == $w and .finished_at == null
  and ([.events[] | select(.phase | startswith("wall")) | .phase] == ["wall", "wall-moved"])
  and ([.events[] | select(.phase == "wall")][0] | .session == $w and .account == "acct-n")
  and ([.events[] | select(.phase == "wall-moved")][0] | .room == "acct-n" and (.waited | type) == "number")' "$R6"
# No account with room: the failover waits, measured, gives up at its limit and leaves the chat alone.
walled=$(jq -r .session "$R6")
cp "$FAKE_BIN/worker-pick" "$WORK/worker-pick.keep"
printf '#!/usr/bin/env bash\nexit 3\n' >"$FAKE_BIN/worker-pick"
assert_fails env NIGHT_RUN_WALL_LIMIT=1 bash -c 'printf "{\"session_id\": \"%s\", \"error\": \"rate_limit\"}" "$1" |
  NIGHT_RUN_WALL_SYNC=1 NIGHT_RUN_WALL_POLL=1 bash "$2/bin/night-run" wall' _ "$walled" "$ROOT" 2>"$WORK/err"
assert grep -qF "no Claude account had room" "$WORK/err"
assert pgrep -f -- "--session-id $walled" >/dev/null
assert jqe --arg w "$walled" '.session == $w and .events[-1].phase == "wall-gave-up" and .events[-1].waited >= 1' "$R6"
# A night that walled too often is not moved again.
cp "$WORK/worker-pick.keep" "$FAKE_BIN/worker-pick"
assert_fails env NIGHT_RUN_WALL_MAX=2 bash -c 'printf "{\"session_id\": \"%s\", \"error\": \"rate_limit\"}" "$1" |
  NIGHT_RUN_WALL_SYNC=1 bash "$2/bin/night-run" wall' _ "$walled" "$ROOT" 2>"$WORK/err"
assert grep -qF "orchestrator walls already" "$WORK/err"
assert jqe --arg w "$walled" '.session == $w and .events[-1].phase == "wall-gave-up"' "$R6"
# A wall after every job closed, before finish, still moves the night: the new orchestrator closes it.
for r in $(jq -r '.jobs[] | select(.state == "pending" or .state == "left") | .ref' "$R6"); do
  night job "$id6" set "$r" state=nothing-to-do >/dev/null
done
wall "$walled" rate_limit >"$WORK/out" || fail "a wall after the last job closed"
assert [ "$(cat "$WORK/out")" = "night $id6 resumed: orchestrator on acct-n" ]
walled=$(jq -r .session "$R6")
stop_chat "$walled"
night finish "$id6" >/dev/null

# Cleanup alone: a new night whose orchestrator prompt carries the sweep word and the cleanup scope.
night start --cleanup >"$WORK/out" || fail "cleanup start"
idc=$(sed -n 's/^night \([^ ]*\) started:.*/\1/p' "$WORK/out")
assert [ -n "$idc" ] && [ "$idc" != "$id6" ]
assert [ "$(last_arg "$idc")" = "сделай чистку — night run $idc cleanup" ]
assert jqe '.jobs == [] and .finished_at == null' "$(record "$idc")"
assert_fails night start --cleanup 2>/dev/null
stop_chat "$(jq -r .session "$(record "$idc")")"

# finish prunes every landed (in main, or a night branch still at its base), clean, not live, not held
# branch of the sweep repositories, night or not, with its worktree. Live = the main checkout, a locked
# worktree or a running night's branch, never recent activity or a process inside; held = Egor's `сделай холд`
# in the owning chat, until the next night finishes; every other branch is a leftover to carry into main, never
# kept. A process inside keeps only a landed worktree's directory from removal.
wt="$WORK/repo/.claude/worktrees"
old() { GIT_COMMITTER_DATE='2026-01-01T00:00:00Z' git -C "$WORK/repo" "$@"; }
printf '%s\n' "$WORK/repo" >"$WORK/sweep-repos"
git -C "$WORK/repo" update-ref "refs/night/$idc/base" "$based_hash"
git -C "$WORK/repo" worktree add -q -b "night/$id/landed" "$wt/landed" "$pushed_hash"
git -C "$WORK/repo" worktree add -q -b "night/$idc/at-base" "$wt/at-base" "$based_hash"
git -C "$WORK/repo" worktree add -q -b "night/$idc/dirty" "$wt/dirty" "$pushed_hash"
: >"$wt/dirty/wip"
git -C "$WORK/repo" worktree add -q -b "night/$idc/open" "$wt/open" "$side_hash"
git -C "$WORK/repo" worktree add -q -b "night/$idc/busy" "$wt/busy" "$pushed_hash"
old worktree add -q -b merged-old "$wt/merged-old" "$pushed_hash"
old branch merged-bare "$pushed_hash"
git -C "$WORK/repo" worktree add -q -b fresh "$wt/fresh" "$pushed_hash"
old worktree add -q -b stale-open "$wt/stale-open" "$side_hash"
old branch stale-bare "$side_hash"
old branch picked-bare "$(old -c user.name=t -c user.email=t@t commit-tree "main^{tree}" -p main^ -m 'main tip, landed as another commit')"
old worktree add -q -b stale-dirty "$wt/stale-dirty" "$pushed_hash"
printf 'wip\n' >"$wt/stale-dirty/wip"
touch -t 202601010000 "$wt/stale-dirty/wip"
old worktree add -q -b edited "$wt/edited" "$pushed_hash"
printf 'wip\n' >"$wt/edited/wip"
old worktree add -q -b plain-busy "$wt/plain-busy" "$side_hash"
(cd "$wt/busy" && exec sleep 600) &
busy=$!
(cd "$wt/plain-busy/" && exec sleep 600) &
plain_busy=$!
old worktree add -q -b addir-busy "$wt/addir-busy" "$side_hash"
perl -e 'sleep 600' -- --add-dir "$wt/addir-busy/" &
addir_busy=$!
printf '%s\n' "$busy" "$plain_busy" "$addir_busy" >>"$DATA/orchestrators"
old worktree add -q -b onhold "$wt/onhold" "$side_hash"
old worktree add -q -b frozen "$wt/frozen" "$side_hash"
git -C "$WORK/repo" worktree lock "$wt/frozen"
journal="$HOME/.cache/claude/review-journal"
mkdir -p "$journal"
export WORDS_LIB="${CLAUDE_SETUP_ROOT:-$(git_projects "$ROOT")/claude-setup}/hooks/lib/words.sh"
grant="$HOME/.cache/claude/words/chat-h/grant.night-hold"
mkdir -p "${grant%/*}"
printf '%s\n' "$wt/onhold" >"$journal/chat-h.repos"
assert_fails env -u CLAUDE_CODE_SESSION_ID bash "$ROOT/bin/night-run" hold 2>/dev/null
(cd "$WORK" && CLAUDE_CODE_SESSION_ID=chat-h night hold) 2>"$WORK/err" && fail "a hold without Egor's word"
assert grep -qF "no fresh night-hold word of Egor's in this chat" "$WORK/err"
jq -n '{family: "night-hold", turn: 3, at: "2026-10-04T01:00:00Z", excerpt: "сделай холд, я ещё тут", lifetime: "ttl:30m"}' >"$grant"
touch -t 202601010000 "$grant"
assert_fails env CLAUDE_CODE_SESSION_ID=chat-h bash "$ROOT/bin/night-run" hold 2>/dev/null
touch "$grant"
(cd "$WORK" && CLAUDE_CODE_SESSION_ID=chat-h night hold) >"$WORK/out" || fail "hold"
assert [ "$(cat "$WORK/out")" = "held repo onhold until the next night finishes: сделай холд, я ещё тут" ]
assert jqe --arg r "$WORK/repo" --arg w "$wt/onhold" '.session == "chat-h" and .words == "сделай холд, я ещё тут"
  and .branches == [{repo: $r, branch: "onhold", worktree: $w}]' "$NIGHTS/holds/chat-h.json"
assert_fails env CLAUDE_CODE_SESSION_ID=nobody bash "$ROOT/bin/night-run" hold 2>/dev/null
behind=$(git -C "$WORK/repo" rev-list --count "$pushed_hash..main")
night leftovers >"$WORK/left" || fail "leftovers"
night leftovers --json >"$WORK/left.json" || fail "leftovers --json"
assert grep -qxF "repo merged-bare · no worktree · landed · +0/-$behind main · 0 dirty · landed" "$WORK/left"
assert grep -qxF "repo stale-open · $wt/stale-open · unlanded · +1/-3 main · 0 dirty · leftover (1 unlanded commits)" "$WORK/left"
assert grep -qxF "repo stale-bare · no worktree · unlanded · +1/-3 main · 0 dirty · leftover (1 unlanded commits)" "$WORK/left"
assert grep -qxF "repo picked-bare · no worktree · landed · +1/-1 main · 0 dirty · landed" "$WORK/left"
assert grep -qxF "repo stale-dirty · $wt/stale-dirty · landed · +0/-$behind main · 1 dirty · leftover (1 uncommitted files)" "$WORK/left"
assert grep -qxF "repo night/$idc/busy · $wt/busy · landed · +0/-$behind main · 0 dirty · landed" "$WORK/left"
assert grep -qxF "repo plain-busy · $wt/plain-busy · unlanded · +1/-3 main · 0 dirty · leftover (1 unlanded commits)" "$WORK/left"
assert grep -qxF "repo addir-busy · $wt/addir-busy · unlanded · +1/-3 main · 0 dirty · leftover (1 unlanded commits)" "$WORK/left"
assert grep -qxF "repo frozen · $wt/frozen · unlanded · +1/-3 main · 0 dirty · live (locked)" "$WORK/left"
assert grep -qxF "repo fresh · $wt/fresh · landed · +0/-$behind main · 0 dirty · landed" "$WORK/left"
assert grep -qxF "repo edited · $wt/edited · landed · +0/-$behind main · 1 dirty · leftover (1 uncommitted files)" "$WORK/left"
assert grep -qxF "repo onhold · $wt/onhold · unlanded · +1/-3 main · 0 dirty · held (Egor: сделай холд, я ещё тут)" "$WORK/left"
assert_fails grep -q '^repo main ' "$WORK/left"
assert grep -qxF "checkout repo: diverged" "$WORK/left"
assert [ "$(wc -l <"$WORK/left" | tr -d ' ')" = 18 ]
assert jqe --arg w "$wt" 'length == 17 and (map(.branch) | index("main")) == null
  and (.[] | select(.branch == "stale-open")) == {repo: ($w | sub("/.claude/worktrees$"; "")), branch: "stale-open",
    worktree: "\($w)/stale-open", landed: false, ahead: 1, behind: 3, dirty: 0, live: false, state: "leftover",
    why: "1 unlanded commits"}
  and ((.[] | select(.branch == "merged-bare")) | .worktree == null and .landed and .state == "landed" and .why == null)
  and ((.[] | select(.branch == "fresh")) | (.live | not) and .state == "landed")
  and ((.[] | select(.branch == "onhold")) | (.live | not) and .state == "held")' "$WORK/left.json"
# An evil merge: its only parent outside main is patch-equivalent to main's tip, so `git cherry` sees nothing
# unlanded, yet the merge's own resolution adds evil.txt.
evil_tree=$(GIT_INDEX_FILE="$WORK/evil.index" bash -c 'git -C "$1" read-tree main &&
  git -C "$1" update-index --add --cacheinfo "100644,$(git -C "$1" hash-object -w --stdin <<<evil),evil.txt" && git -C "$1" write-tree' _ "$WORK/repo")
old branch evil-bare "$(old -c user.name=t -c user.email=t@t commit-tree "$evil_tree" -p main^ -p picked-bare -m 'evil merge')"
night leftovers >"$WORK/left-evil" || fail "leftovers with an evil merge"
assert grep -qxF "repo evil-bare · no worktree · unlanded · +2/-1 main · 0 dirty · leftover (2 unlanded commits)" "$WORK/left-evil"
git -C "$WORK/repo" branch -q -D evil-bare || fail "drop the evil merge"
sleep 0.3
night finish "$idc" >"$WORK/out" || fail "finish with worktrees"
busy_alive=0; kill -0 "$busy" 2>/dev/null && busy_alive=1
kill "$busy" "$plain_busy" "$addir_busy" 2>/dev/null
assert [ "$busy_alive" = 1 ]
assert grep -qxF "pruned repo night/$id/landed" "$WORK/out"
assert grep -qxF "pruned repo night/$idc/at-base" "$WORK/out"
assert grep -qxF "pruned repo merged-old" "$WORK/out"
assert grep -qxF "pruned repo merged-bare" "$WORK/out"
assert grep -qxF "pruned repo picked-bare" "$WORK/out"
assert grep -qxF "pruned repo fresh" "$WORK/out"
assert grep -qxF "leftover repo night/$idc/dirty: 1 uncommitted files" "$WORK/out"
assert grep -qxF "leftover repo night/$idc/open: 1 unlanded commits" "$WORK/out"
assert grep -qxF "leftover repo stale-open: 1 unlanded commits" "$WORK/out"
assert grep -qxF "leftover repo stale-bare: 1 unlanded commits" "$WORK/out"
assert grep -qxF "leftover repo stale-dirty: 1 uncommitted files" "$WORK/out"
assert grep -qxF "live repo night/$idc/busy: processes inside: $busy sleep 600" "$WORK/out"
assert grep -qxF "leftover repo plain-busy: 1 unlanded commits" "$WORK/out"
assert grep -qxF "leftover repo addir-busy: 1 unlanded commits" "$WORK/out"
assert grep -qxF "live repo frozen: locked" "$WORK/out"
assert grep -qxF "leftover repo edited: 1 uncommitted files" "$WORK/out"
assert grep -qxF "held repo onhold: Egor: сделай холд, я ещё тут" "$WORK/out"
assert_fails grep -q '^kept ' "$WORK/out"
assert [ "$(wc -l <"$WORK/out" | tr -d ' ')" = 18 ]
assert [ ! -e "$wt/landed" ] && [ ! -e "$wt/at-base" ] && [ ! -e "$wt/merged-old" ] && [ ! -e "$wt/fresh" ]
assert [ -e "$wt/dirty/wip" ] && [ -d "$wt/open" ] && [ -e "$wt/edited/wip" ] && [ -d "$wt/stale-open" ] && [ -e "$wt/stale-dirty/wip" ] && [ -d "$wt/onhold" ] && [ -d "$wt/busy" ] && [ -d "$wt/frozen" ]
for gone in "night/$id/landed" merged-old merged-bare picked-bare fresh; do
  assert_fails git -C "$WORK/repo" rev-parse -q --verify "refs/heads/$gone"
done
for stays in "night/$idc/open" "night/$idc/busy" stale-open stale-bare stale-dirty edited plain-busy addir-busy onhold frozen; do
  assert git -C "$WORK/repo" rev-parse -q --verify "refs/heads/$stays" >/dev/null
done
assert jqe '([.leftovers[] | .branch] | sort) == (["addir-busy", "edited", "night/'"$idc"'/dirty", "night/'"$idc"'/open", "plain-busy", "stale-bare", "stale-dirty", "stale-open"] | sort)
  and .held == [{repo: "repo", branch: "onhold", why: "Egor: сделай холд, я ещё тут"}]' "$(record "$idc")"
assert grep -qxF "leftover · repo · stale-open · 1 unlanded commits" <(night report "$idc")
assert grep -qxF "held · repo · onhold · Egor: сделай холд, я ещё тут" <(night report "$idc")
# The hold lasted that one night: its finish released it.
assert [ ! -e "$NIGHTS/holds/chat-h.json" ]
assert grep -qxF "repo onhold · $wt/onhold · unlanded · +1/-3 main · 0 dirty · leftover (1 unlanded commits)" <(night leftovers)

# A leftover job adopts the branch into the night's namespace, where workers may commit: its WIP
# committed, night/<id>/leftover-<slug> at its tip in a night worktree, the old worktree and branch gone.
nwt="$wt/night-$idc-leftover-stale-dirty"
night job "$idc" add leftover stale-dirty >"$WORK/out" || fail "adopt a dirty leftover"
assert grep -qxF "adopted repo stale-dirty into night/$idc/leftover-stale-dirty at $nwt" "$WORK/out"
assert grep -qxF "night $idc: job leftover leftover-stale-dirty added" "$WORK/out"
assert [ "$(git -C "$WORK/repo" show "night/$idc/leftover-stale-dirty:wip")" = wip ]
assert [ "$(git -C "$WORK/repo" log -1 --format=%s "night/$idc/leftover-stale-dirty")" = "Leftover WIP from stale-dirty, adopted by night $idc" ]
assert [ "$(git -C "$WORK/repo" rev-parse "night/$idc/leftover-stale-dirty^")" = "$pushed_hash" ]
assert [ "$(git -C "$nwt" symbolic-ref --short HEAD)" = "night/$idc/leftover-stale-dirty" ] && [ "$(cat "$nwt/wip")" = wip ]
assert [ -z "$(git -C "$nwt" status --porcelain)" ]
assert [ ! -e "$wt/stale-dirty" ]
assert_fails git -C "$WORK/repo" rev-parse -q --verify refs/heads/stale-dirty
assert jqe --arg r "$WORK/repo" --arg w "$wt/stale-dirty" --arg n "$nwt" --arg t "$(git -C "$WORK/repo" rev-parse "night/$idc/leftover-stale-dirty")" \
  '.jobs[-1] == {kind: "leftover", ref: "leftover-stale-dirty", state: "pending", reason: null,
    branch: "night/'"$idc"'/leftover-stale-dirty", review: null, commits: [], pushed: false,
    adopted: [{repo: $r, branch: "stale-dirty", worktree: $w, tip: $t, night_worktree: $n}]}' "$(record "$idc")"
assert grep -q "^leftover stale-dirty · unfinished	2		leftover-stale-dirty	leftover	1$" <(night latest --menu)
night job "$idc" add leftover stale-bare >"$WORK/out" || fail "adopt a bare leftover"
assert [ "$(git -C "$WORK/repo" rev-parse "night/$idc/leftover-stale-bare")" = "$side_hash" ]
assert [ -d "$wt/night-$idc-leftover-stale-bare" ]
assert_fails git -C "$WORK/repo" rev-parse -q --verify refs/heads/stale-bare
assert jqe '.jobs[-1].adopted[0] | .branch == "stale-bare" and .worktree == null' "$(record "$idc")"
# Refused, nothing touched: a live branch, a held one, a landed one, main, an unknown name, a job already there.
old branch landed-x "$pushed_hash"
(cd "$WORK" && CLAUDE_CODE_SESSION_ID=chat-h night hold) >/dev/null || fail "hold again"
for refused in "onhold:onhold is held in repo: Egor: сделай холд" \
  "landed-x:landed-x is no leftover: landed" \
  "main:no branch main in the sweep repositories" "nosuch:no branch nosuch in the sweep repositories"; do
  assert_fails night job "$idc" add leftover "${refused%%:*}" 2>"$WORK/err"
  assert grep -qF "${refused#*:}" "$WORK/err"
done
assert_fails night job "$idc" add leftover stale-open --branch x 2>/dev/null
assert git -C "$WORK/repo" rev-parse -q --verify refs/heads/landed-x >/dev/null
assert_fails night job "$idc" add leftover onhold --ready "owner says done" 2>"$WORK/err"
assert grep -qxF "night-run: onhold is held in repo: Egor: сделай холд, я ещё тут" "$WORK/err"
# A second hold from another worktree adds to the first; a running night is named as the one whose finish drops it.
printf '%s\n' "$wt/frozen" >"$journal/chat-h.repos"
sleep 600 & runner=$!
printf '%s\n' "$runner" >>"$DATA/orchestrators"
jq -n --argjson p "$runner" '{id: "nrun", started_at: "2026-01-04T00:00:00Z", finished_at: null, session: null, opener: $p, jobs: []}' >"$(record nrun)"
(cd "$WORK" && CLAUDE_CODE_SESSION_ID=chat-h night hold) >"$WORK/out" || fail "a second hold"
assert [ "$(cat "$WORK/out")" = "held repo frozen until night nrun finishes: сделай холд, я ещё тут
held repo onhold until night nrun finishes: сделай холд, я ещё тут" ]
kill "$runner"; rm "$(record nrun)"
printf '%s\n' "$wt/onhold" >"$journal/chat-h.repos"
rm "$NIGHTS/holds/chat-h.json"
assert [ -d "$wt/onhold" ] && [ -d "$wt/stale-open" ]
# Recent activity keeps no branch out of the night: one committed a minute ago is a leftover adopted
# without a word from its owner.
git -C "$WORK/repo" worktree add -q -b recent "$wt/recent" "$pushed_hash"
printf 'r\n' >"$wt/recent/r" && git -C "$wt/recent" add r && git -C "$wt/recent" -c user.name=t -c user.email=t@t commit -qm recent
assert grep -qxF "repo recent · $wt/recent · unlanded · +1/-$behind main · 0 dirty · leftover (1 unlanded commits)" <(night leftovers)
night job "$idc" add leftover recent >"$WORK/out" || fail "a branch committed a minute ago is adopted"
assert grep -qxF "adopted repo recent into night/$idc/leftover-recent at $wt/night-$idc-leftover-recent" "$WORK/out"
assert jqe '.jobs[-1] | .ref == "leftover-recent" and (has("handover") | not)' "$(record "$idc")"
# A process inside never keeps a branch out of the night: adopted, only its old directory stays. The
# caller's own process never holds even that.
old worktree add -q -b inhabited "$wt/inhabited" "$side_hash"
(cd "$wt/inhabited" && exec sleep 600) >/dev/null 2>&1 &
inhabited=$!
printf '%s\n' "$inhabited" >>"$DATA/orchestrators"
old worktree add -q -b self "$wt/self" "$side_hash"
sleep 0.5
night job "$idc" add leftover inhabited >"$WORK/out" || fail "a process inside never refuses an adoption"
kill "$inhabited" 2>/dev/null
assert grep -qxF "adopted repo inhabited into night/$idc/leftover-inhabited at $wt/night-$idc-leftover-inhabited; the old one stays: processes inside: $inhabited sleep 600" "$WORK/out"
(cd "$wt/self" && night job "$idc" add leftover self) >"$WORK/out" || fail "adopt from inside"
assert grep -qxF "adopted repo self into night/$idc/leftover-self at $wt/night-$idc-leftover-self" "$WORK/out"
assert [ ! -e "$wt/self" ]
# --ready records the owner's handover with who, when and why; a live reason still refuses it.
old worktree add -q -b held "$wt/held" "$side_hash"
git -C "$WORK/repo" worktree lock "$wt/held"
assert_fails night job "$idc" add leftover held --ready "owner says done" 2>"$WORK/err"
assert grep -qxF "night-run: held is live in repo: locked" "$WORK/err"
assert_fails night job "$idc" add debt handed --ready "owner says done" 2>/dev/null
assert [ -d "$wt/edited" ]
CLAUDE_CODE_SESSION_ID=owner-1 night job "$idc" add leftover edited --ready "owner declared it finished" >"$WORK/out" ||
  fail "a handed-over branch is adopted"
assert grep -qxF "night $idc: job leftover leftover-edited added" "$WORK/out"
assert [ "$(git -C "$WORK/repo" show "night/$idc/leftover-edited:wip")" = wip ]
assert jqe '.jobs[-1] | .ref == "leftover-edited" and .handover.by == "owner-1"
  and .handover.why == "owner declared it finished" and (.handover.at | test("^[0-9-]+T[0-9:]+Z$"))' "$(record "$idc")"
assert jqe '[.jobs[] | select(.ref == "leftover-stale-dirty" or .ref == "leftover-stale-bare") | has("handover")] == [false, false]' "$(record "$idc")"
assert grep -qE "^pending · leftover · leftover-edited · .* · handed over by owner-1 at [0-9]{2}:[0-9]{2}: owner declared it finished$" \
  <(night report "$idc")
# One name, every sweep repository: a leftover branch in two repositories is adopted in both as one job;
# live in any of them, it is refused everywhere.
git init -q -b main "$WORK/repo2"
git -C "$WORK/repo2" -c user.name=t -c user.email=t@t commit -q --allow-empty -m root
git -C "$WORK/repo2" update-ref "refs/night/$idc/base" HEAD
for r in repo repo2; do
  c=$(git -C "$WORK/$r" -c user.name=t -c user.email=t@t commit-tree "main^{tree}" -p main -m "$r work")
  GIT_COMMITTER_DATE='2026-01-01T00:00:00Z' git -C "$WORK/$r" branch both "$c"
done
GIT_COMMITTER_DATE='2026-01-01T00:00:00Z' git -C "$WORK/repo" branch split "$side_hash"
git -C "$WORK/repo2" worktree add -q -b split "$WORK/repo2/.claude/worktrees/split"
git -C "$WORK/repo2" worktree lock "$WORK/repo2/.claude/worktrees/split"
printf '%s\n' "$WORK/repo" "$WORK/repo2" >"$WORK/sweep-repos"
assert_fails night job "$idc" add leftover split 2>"$WORK/err"
assert grep -qxF "night-run: split is live in repo2: locked" "$WORK/err"
assert git -C "$WORK/repo" rev-parse -q --verify refs/heads/split >/dev/null
night job "$idc" add leftover both >"$WORK/out" || fail "adopt in every repository"
assert [ "$(grep -c '^adopted repo2\{0,1\} both into night/'"$idc"'/leftover-both at ' "$WORK/out")" = 2 ]
for r in repo repo2; do
  assert [ "$(git -C "$WORK/$r" log -1 --format=%s "night/$idc/leftover-both")" = "$r work" ]
  assert_fails git -C "$WORK/$r" rev-parse -q --verify refs/heads/both
done
assert jqe '.jobs[-1] | .ref == "leftover-both" and ([.adopted[] | .repo | split("/") | last] == ["repo", "repo2"])' "$(record "$idc")"
assert_fails night job "$idc" add leftover both 2>/dev/null
# A failure in a later repository undoes the night branches made so far, so the job can be retried.
for r in repo repo2; do
  c=$(git -C "$WORK/$r" -c user.name=t -c user.email=t@t commit-tree "main^{tree}" -p main -m "$r half")
  GIT_COMMITTER_DATE='2026-01-01T00:00:00Z' git -C "$WORK/$r" branch half "$c"
done
chmod 555 "$WORK/repo2/.claude/worktrees"
assert_fails night job "$idc" add leftover half 2>"$WORK/err"
chmod 755 "$WORK/repo2/.claude/worktrees"
assert grep -qF "cannot make night/$idc/leftover-half in $WORK/repo2" "$WORK/err"
for r in repo repo2; do
  assert_fails git -C "$WORK/$r" rev-parse -q --verify "refs/heads/night/$idc/leftover-half"
  assert git -C "$WORK/$r" rev-parse -q --verify refs/heads/half >/dev/null
  assert [ ! -e "$WORK/$r/.claude/worktrees/night-$idc-leftover-half" ]
done
night job "$idc" add leftover half >/dev/null || fail "a retry adopts after the undo"
# A handover covers only its own chat's branch: --ready on a name in two repositories is refused until
# --repo names them, and the other repository's live branch of that name stays untouched.
for r in repo repo2; do
  git -C "$WORK/$r" worktree add -q -b shared "$WORK/$r/.claude/worktrees/shared" main
  printf 'live\n' >"$WORK/$r/.claude/worktrees/shared/live"
done
state() { git -C "$WORK/$1" rev-parse shared; git -C "$WORK/$1/.claude/worktrees/shared" status --porcelain --untracked-files=all; }
for r in repo repo2; do state "$r" >"$WORK/$r.shared"; done
assert_fails night job "$idc" add leftover shared --ready "owner says done" 2>"$WORK/err"
assert grep -qxF "night-run: shared is in repo repo2: --ready hands over one chat's branch, so name the repositories it covers and retry with --repo repo or --repo repo2" "$WORK/err"
for r in repo repo2; do
  assert cmp -s <(state "$r") "$WORK/$r.shared"
  assert_fails git -C "$WORK/$r" rev-parse -q --verify "refs/heads/night/$idc/leftover-shared"
done
night job "$idc" add leftover shared --ready "owner says done" --repo repo2 >"$WORK/out" || fail "adopt in the named repository"
assert grep -qx "adopted repo2 shared into night/$idc/leftover-shared at .*" "$WORK/out"
assert [ "$(git -C "$WORK/repo2" show "night/$idc/leftover-shared:live")" = live ]
assert cmp -s <(state repo) "$WORK/repo.shared"
assert_fails git -C "$WORK/repo" rev-parse -q --verify "refs/heads/night/$idc/leftover-shared"
assert jqe '.jobs[-1] | .ref == "leftover-shared" and ([.adopted[] | .repo | split("/") | last] == ["repo2"])' "$(record "$idc")"
assert_fails night job "$idc" add leftover nosuch --repo nowhere 2>"$WORK/err"
assert grep -qF "no repository nowhere" "$WORK/err"
# An old worktree holding ignored files stays, removing it would delete them; so does a Code fixer
# run's own worktree, which code-doctor check proves the run from.
printf 'local.env\n' >>"$WORK/repo/.git/info/exclude"
old worktree add -q -b ignoring "$wt/ignoring" "$side_hash"
printf 'secret\n' >"$wt/ignoring/local.env"
night job "$idc" add leftover ignoring >"$WORK/out" || fail "adopt a leftover holding ignored files"
assert grep -qF "; the old one stays: it holds ignored files (local.env)" "$WORK/out"
assert [ "$(cat "$wt/ignoring/local.env")" = secret ]
old worktree add -q -b night/n0/code-code-20261001T020700Z-0b0b "$wt/code-old" "$side_hash"
night job "$idc" add leftover night/n0/code-code-20261001T020700Z-0b0b >"$WORK/out" || fail "adopt a Code fixer leftover"
assert grep -qF "; the old one stays: code-doctor check reads the Code fixer run from it" "$WORK/out"
assert [ -d "$wt/code-old" ]
printf '%s\n' "$WORK/repo" >"$WORK/sweep-repos"

# A vendor job is named by its branch's vendor, whatever run ref its updater fixer got.
night job "$idc" add vendor updater-release-20261001T020703Z-0d10 --branch "night/$idc/codex" >/dev/null
assert grep -q "^codex update · " <(night latest --menu)

# Fixer runs recorded under an area's old name keep their menu word; the doctor's own area names no word.
for ref in llm-health-20261001T020632Z-3671 harness-self-20261001T020659Z-1dba updater-machinery-20261001T020659Z-1dba \
    llm-doctor-20261001T030000Z-0a0a harness-hook-waits-20261001T020655Z-4a9f code-code-20261001T020700Z-0b0b; do
  night job "$idc" add fixer "$ref" >/dev/null || fail "job add $ref"
done
assert [ "$(night latest --menu | cut -f1 | grep ' fixer' | sed 's/ · .*//' | paste -sd, -)" \
  = "LLM fixer: debt,Harness fixer,Updater fixer,LLM fixer,Harness fixer: hook waits,Code fixer" ]

# A start killed before it recorded the session leaves a night that runs only while that start lives.
rm "$NIGHTS"/*.json
opening() { # opener-pid-json
  jq -n --argjson o "$1" '{id: "20261001T000000Z-0pen", started_at: "2026-10-01T00:00:00Z", finished_at: null,
    session: null, account: null, command: null, note: null, doctors_before: {}, doctors_after: null, jobs: [],
    opener: $o} | if $o == null then del(.opener) else . end' >"$(record 20261001T000000Z-0pen)"
}
opening $$
assert_fails night start 2>"$WORK/err"
assert grep -qF "night 20261001T000000Z-0pen is still running" "$WORK/err"
assert [ "$(night latest --menu | head -1 | cut -f3)" = 1 ]
sleep 0 &
dead=$!
wait "$dead"
for opener in "$dead" null; do
  opening "$opener"
  assert [ "$(night latest --menu | head -1 | cut -f3)" = 0 ]
  assert grep -q 'UNFINISHED' <(night report 2>/dev/null; night latest --menu)
done

# report's header: the orchestrator's runs, rounds and transcripts in the night's window, one message
# counted once, weighed against the newest earlier FINISHED night.
SP="$WORK/spend"
spend_night() { # id started finished-or-null session jobs
  jq -n --arg i "$1" --arg s "$2" --argjson f "$3" --arg o "$4" --argjson j "${5:-[]}" '{id: $i, started_at: $s,
    finished_at: $f, session: $o, account: null, command: null, note: null, doctors_before: {}, doctors_after: null,
    jobs: $j}' >"$SP/doctors/nights/$1.json"
}
assistant() { # id timestamp usage-json
  jq -nc --arg i "$1" --arg t "$2" --argjson u "$3" '{type: "assistant", timestamp: $t, message: {id: $i, usage: $u}}'
}
spend_run() { # run launcher meta-json
  mkdir -p "$SP/runs/$1"
  printf '%s\n' "$2" >"$SP/runs/$1/launcher"
  printf '%s\n' "$3" >"$SP/runs/$1/meta.json"
}
mkdir -p "$SP/doctors/nights" "$SP/profiles/p1/projects/-x/S1/subagents" "$SP/profiles/p2/projects/-x" \
  "$SP/profiles/p1/projects/-x/T1/subagents" "$SP/codex/acct/sessions/2026/01/02" "$SP/stats/benches"
spend_night 20260101T000000Z-aaaa 2026-01-01T00:00:00Z '"2026-01-01T01:00:00Z"' S0
spend_night 20260101T120000Z-cccc 2026-01-01T12:00:00Z null S9
spend_night 20260103T000000Z-dddd 2026-01-03T00:00:00Z '"2026-01-03T01:00:00Z"' S9
spend_night 20260102T000000Z-bbbb 2026-01-02T00:00:00Z '"2026-01-02T02:00:00Z"' S1 '[{"ref": "a", "kind": "fixer",
  "state": "merged", "commits": []}, {"ref": "b", "kind": "fixer", "state": "merged", "commits": []}, {"ref": "c",
  "kind": "vendor", "state": "merged", "commits": []}, {"ref": "d", "kind": "fixer", "state": "left", "commits": []},
  {"ref": "e", "kind": "debt", "state": "blocked-on-egor", "commits": []}]'
assistant o0 2026-01-01T00:10:00Z '{"output_tokens": 1600000}' >"$SP/profiles/p1/projects/-x/S0.jsonl"
{ assistant o1 2026-01-02T00:10:00.000Z '{"output_tokens": 200000, "cache_read_input_tokens": 10000000}'
  assistant o2 2026-01-02T03:00:00.000Z '{"output_tokens": 9000000}'; } >"$SP/profiles/p1/projects/-x/S1.jsonl"
assistant o3 2026-01-02T00:20:00Z '{"cache_creation_input_tokens": 400000}' >"$SP/profiles/p1/projects/-x/S1/subagents/agent-a.jsonl"
ln -s "$SP/profiles/p1/projects/-x/S1.jsonl" "$SP/profiles/p2/projects/-x/S1.jsonl"
T1="$SP/profiles/p1/projects/-x/T1.jsonl"
{ assistant m1 2026-01-02T00:02:00Z '{"cache_creation_input_tokens": 2000000, "cache_read_input_tokens": 10000000, "output_tokens": 200000}'
  assistant m1 2026-01-02T00:02:00Z '{"cache_creation_input_tokens": 2000000, "cache_read_input_tokens": 10000000, "output_tokens": 200000}'
  assistant m2 2026-01-02T00:03:00Z '{"output_tokens": 300000}'; } >"$T1"
assistant m3 2026-01-02T00:04:00Z '{"output_tokens": 500000}' >"$SP/profiles/p1/projects/-x/T1/subagents/agent-b.jsonl"
opus='"vendor": "claudeb", "account": "p1", "served_model": "claude-opus-5-5"'
spend_run claudeb-1767312100-1-aaaa S1 "{$opus, \"started_at\": 1767312100, \"ended_at\": 1767315700}"
printf '%s\n' "$T1" >"$SP/runs/claudeb-1767312100-1-aaaa/session-file"
# A walled reroute restamps started_at; the hours run from the launch.
spend_run claudeb-1767312200-2-bbbb S1 "{$opus, \"pid_started_at\": 1767312100, \"started_at\": 1767315700, \"ended_at\": 1767317500}"
printf '%s\n' "$T1" >"$SP/runs/claudeb-1767312200-2-bbbb/session-file"
spend_run codex-1767312300-3-cccc S1 '{"vendor": "codex", "account": "acct", "served_model": "gpt-6-astra",
  "started_at": 1767312300, "ended_at": 1767314100}'
printf 'session id: c0dex-5e55\n' >"$SP/runs/codex-1767312300-3-cccc/err"
{ jq -nc '{type: "event_msg", payload: {type: "token_count", info: {total_token_usage: {input_tokens: 1000000}}}}'
  jq -nc '{type: "event_msg", payload: {type: "token_count", info: {total_token_usage: {input_tokens: 3000000,
    cached_input_tokens: 2000000, output_tokens: 400000}}}}'; } >"$SP/codex/acct/sessions/2026/01/02/rollout-c0dex-5e55.jsonl"
spend_run claudeb-1767312400-4-dddd S2 "{$opus, \"started_at\": 1767312400, \"ended_at\": 1767399999}"
spend_run claudeb-1767305000-5-eeee S1 "{$opus, \"started_at\": 1767305000, \"ended_at\": 1767399999}"
spend_run claudeb-1767312500-6-ffff S1 "{$opus, \"started_at\": 1767312500}"
bench() { mkdir -p "$SP/stats/benches/$1"; printf '%s\n' "$2" >"$SP/stats/benches/$1/meta.json"; }
bench 20260102T003000Z-1111111 '{"session": "S1"}'
B="$SP/stats/benches/20260102T003000Z-1111111"
row='{"id": "r1", "input": 0, "cache_read": 20000000, "cache_5m": 1000000, "cache_1h": 1000000, "output": 600000}'
printf '%s\n' "$row" >"$B/claude-usage-opus-high~c0.jsonl"
printf '%s\n' "$row" >"$B/claude-usage-opus-high~c0~a1.jsonl"
printf '{"id": "j1", "cache_read": 5000000, "output": 400000}\n' >"$B/claude-usage-judge~b1.jsonl"
printf '{"total_tokens": 5400000}\n' >"$B/usage-judge~b1.jsonl"
printf '{"total_tokens": 5400000}\n' >"$B/usage-judge.jsonl"
bench 20260102T010000Z-2222222 '{}'
printf '{"total_tokens": 3000000}\n' >"$SP/stats/benches/20260102T010000Z-2222222/usage-judge.jsonl"
bench 20260102T011500Z-3333333 '{"session": "S2"}'
printf '%s\n' "$row" >"$SP/stats/benches/20260102T011500Z-3333333/claude-usage-x.jsonl"
bench 20260102T050000Z-4444444 '{"session": "S1"}'
printf '%s\n' "$row" >"$SP/stats/benches/20260102T050000Z-4444444/claude-usage-x.jsonl"
TZ=UTC DOCTORS_DIR="$SP/doctors" WORKER_RUN_DIR="$SP/runs" CLAUDEB_PROFILES_ROOT="$SP/profiles" \
  WORKER_STATS_DIR="$SP/stats" CODEX_PROFILES_DIR="$SP/codex" CHAT_NAME_ROOTS="$SP/profiles/p2/projects:$SP/profiles/p1/projects" \
  CHAT_NAMES_CACHE="$SP/chat-names.json" night report 20260102T000000Z-bbbb >"$WORK/spend-report" ||
  fail "spend report"
assert [ "$(body "$WORK/spend-report" | head -8)" = "duration · 02 Jan 00:00 – 02 Jan 02:00 · 2.0 h
jobs · landed 3 (fixer 2, vendor 1) · left 1 (fixer 1) · other 1 (debt 1)
agents · 4 worker runs (3 claudeb/claude-opus-5-5, 1 codex/gpt-6-astra) · 3.0 h wall-clock · 1 without a transcript
review rounds · 2
spend fixers · out 1.4M · cache write 2.0M · cache read 12.0M · 11.7M weighted
spend reviews · out 1.0M · cache write 2.0M · cache read 25.0M · 13.0M weighted
spend orchestrator · out 0.2M · cache write 0.4M · cache read 10.0M · 2.5M weighted
spend total · 27.2M weighted · 3.40× night 20260101T000000Z-aaaa (8.0M)" ]
assert [ "$(body "$WORK/spend-report" | sed -n '9,11p')" = "reviews · per-branch 0 rounds (0.0M weighted) · other 2 rounds (13.0M weighted)
problems · no snapshot
fixer spend without proof · no snapshot" ]
assert [ "$(body "$WORK/spend-report" | sed -n 12p | cut -d' ' -f1-2)" = "night 20260102T000000Z-bbbb" ]

# Observational churn block: review rounds per-branch vs other, problems touched again without proof,
# regressed from after snapshot, proved excluded, fixer spend without proof, and rewrites in past 7 days.
CHURN="$WORK/churn"
mkdir -p "$CHURN/doctors/nights" "$CHURN/doctors/runs" "$CHURN/runs" "$CHURN/stats/benches" "$CHURN/profiles/p1/projects/-x"
git init -q -b main "$CHURN/repo"
git -C "$CHURN/repo" config user.email "test@example.com"
git -C "$CHURN/repo" config user.name "Test"
printf 'ledger.json linguist-generated\n' >"$CHURN/repo/.gitattributes"
printf 'line1 old\n' >"$CHURN/repo/code.txt"
printf 'ignored\n' >"$CHURN/repo/ledger.json"
git -C "$CHURN/repo" add .
GIT_AUTHOR_DATE="2026-01-01T00:00:00Z" GIT_COMMITTER_DATE="2026-01-01T00:00:00Z" git -C "$CHURN/repo" commit -q -m "initial"
printf 'line1 old\nline2 recent\n' >"$CHURN/repo/code.txt"
git -C "$CHURN/repo" add code.txt
GIT_AUTHOR_DATE="2026-01-28T00:00:00Z" GIT_COMMITTER_DATE="2026-01-28T00:00:00Z" git -C "$CHURN/repo" commit -q -m "Night sweep 20260128: add line 2"
printf 'line replacement\n' >"$CHURN/repo/code.txt"
printf 'new ledger\n' >"$CHURN/repo/ledger.json"
git -C "$CHURN/repo" add code.txt ledger.json
GIT_AUTHOR_DATE="2026-01-31T01:00:00Z" GIT_COMMITTER_DATE="2026-01-31T01:00:00Z" git -C "$CHURN/repo" commit -q -m "rewrite lines"
h_rewrite=$(git -C "$CHURN/repo" rev-parse HEAD)
printf '%s\n' "$CHURN/repo" >"$CHURN/sweep-repos"

jq -n '{id: "20260130T000000Z-prev", started_at: "2026-01-30T00:00:00Z", finished_at: "2026-01-30T02:00:00Z",
  session: "S_PREV", account: null, command: null, note: null, doctors_before: {}, doctors_after: null,
  jobs: [{ref: "run-prev", kind: "fixer", state: "merged", commits: []}]}' >"$CHURN/doctors/nights/20260130T000000Z-prev.json"
printf '{"id": "run-prev", "doctor": "harness", "decisions": [{"id": "P_OPEN"}, {"id": "P_PROVED"}]}\n' \
  >"$CHURN/doctors/runs/run-prev.json"

jq -n --arg h "$h_rewrite" --arg r "$CHURN/repo" '{id: "20260131T000000Z-now", started_at: "2026-01-31T00:00:00Z",
  finished_at: "2026-01-31T02:00:00Z", session: "S_NOW", account: null, command: null, note: null,
  doctors_before: {}, doctors_after: null,
  doctor_problems_before: {harness: {P_OPEN: "open", P_PROVED: "open"}},
  doctor_problems_after: {harness: {P_OPEN: "open", P_PROVED: "proved", P_REG: "regressed"}},
  jobs: [
    {ref: "run-unproven", kind: "fixer", state: "merged", branch: "night/20260131T000000Z-now/run-unproven",
     review: null, commits: [{repo: $r, hash: $h}]},
    {ref: "run-proven", kind: "fixer", state: "merged", branch: "night/20260131T000000Z-now/run-proven",
     review: "20260131T003000Z-bench-per-branch", commits: []}
  ]}' >"$CHURN/doctors/nights/20260131T000000Z-now.json"
printf '{"id": "run-unproven", "doctor": "harness", "decisions": [{"id": "P_OPEN"}]}\n' \
  >"$CHURN/doctors/runs/run-unproven.json"
printf '{"id": "run-proven", "doctor": "harness", "decisions": [{"id": "P_PROVED"}]}\n' \
  >"$CHURN/doctors/runs/run-proven.json"

mkdir -p "$CHURN/runs/claudeb-1769821200-1-unproven" "$CHURN/runs/claudeb-1769822400-2-proven"
printf 'S_NOW\n' >"$CHURN/runs/claudeb-1769821200-1-unproven/launcher"
printf 'S_NOW\n' >"$CHURN/runs/claudeb-1769822400-2-proven/launcher"
printf '{"vendor": "claudeb", "started_at": 1769821200, "ended_at": 1769822000, "ref": "run-unproven"}\n' \
  >"$CHURN/runs/claudeb-1769821200-1-unproven/meta.json"
printf '{"vendor": "claudeb", "started_at": 1769822400, "ended_at": 1769823000, "ref": "run-proven"}\n' \
  >"$CHURN/runs/claudeb-1769822400-2-proven/meta.json"
assistant u1 2026-01-31T00:10:00Z '{"output_tokens": 1000000}' >"$CHURN/profiles/p1/projects/-x/U1.jsonl"
assistant u2 2026-01-31T00:20:00Z '{"output_tokens": 2000000}' >"$CHURN/profiles/p1/projects/-x/U2.jsonl"
printf '%s\n' "$CHURN/profiles/p1/projects/-x/U1.jsonl" >"$CHURN/runs/claudeb-1769821200-1-unproven/session-file"
printf '%s\n' "$CHURN/profiles/p1/projects/-x/U2.jsonl" >"$CHURN/runs/claudeb-1769822400-2-proven/session-file"

mkdir -p "$CHURN/stats/benches/20260131T003000Z-bench-per-branch" "$CHURN/stats/benches/20260131T010000Z-bench-other"
printf '{"session": "S_NOW"}\n' >"$CHURN/stats/benches/20260131T003000Z-bench-per-branch/meta.json"
printf '{"session": "S_NOW"}\n' >"$CHURN/stats/benches/20260131T010000Z-bench-other/meta.json"
printf '{"id": "b1", "output": 400000}\n' >"$CHURN/stats/benches/20260131T003000Z-bench-per-branch/claude-usage-x.jsonl"
printf '{"id": "b2", "output": 600000}\n' >"$CHURN/stats/benches/20260131T010000Z-bench-other/claude-usage-x.jsonl"

TZ=UTC DOCTORS_DIR="$CHURN/doctors" WORKER_RUN_DIR="$CHURN/runs" CLAUDEB_PROFILES_ROOT="$CHURN/profiles" \
  WORKER_STATS_DIR="$CHURN/stats" NIGHT_RUN_SWEEP_REPOS="$CHURN/sweep-repos" \
  CHAT_NAME_ROOTS="$CHURN/profiles/p1/projects" CHAT_NAMES_CACHE="$CHURN/chat-names.json" \
  night report 20260131T000000Z-now >"$WORK/churn-report" || fail "churn report"

assert [ "$(body "$WORK/churn-report" | sed -n '9,14p')" = "reviews · per-branch 1 rounds (2.0M weighted) · other 1 rounds (3.0M weighted)
problems · 1 touched again without proof · 1 regressed
problem · harness/P_OPEN · nights touched 2 · now open
fixer spend without proof · 5.0M weighted of 15.0M
rewrite · 1 of 2 lines deleted tonight were written in the 7 days before (1 by earlier night commits)
night 20260131T000000Z-now · 00:00–02:00" ]

# Comparison table: this night and the two previous finished nights with jobs, oldest left; an older one
# and a night with no jobs stay out; a value with no source is a dash, never a number.
TB="$WORK/table"
mkdir -p "$TB/doctors/nights" "$TB/doctors/night-ledger" "$TB/runs" "$TB/stats/benches" "$TB/profiles"
: >"$TB/sweep-repos"
tb_night() { # id started finished jobs before after [suites]
  jq -n --arg i "$1" --arg s "$2" --arg f "$3" --argjson j "$4" --argjson b "$5" --argjson a "$6" --argjson u "${7:-null}" \
    '{id: $i, started_at: $s, finished_at: $f, session: "S-\($i)", account: null, command: null, note: null,
      doctors_before: $b, doctors_after: $a, jobs: $j} + (if $u then {suites: $u} else {} end)' >"$TB/doctors/nights/$1.json"
}
tb_jobs() { jq -nc '[$ARGS.positional[] | {ref: ., kind: "fixer", state: ., commits: []}]' --args "$@"; }
tb_night 20260201T000000Z-0001 2026-02-01T00:00:00Z 2026-02-01T05:00:00Z "$(tb_jobs merged)" '{}' null
tb_night 20260202T000000Z-a0b1 2026-02-02T00:00:00Z 2026-02-02T09:48:00Z "$(tb_jobs merged merged left)" \
  '{"llm": 5, "harness": 3}' null
tb_night 20260203T000000Z-c2d3 2026-02-03T00:00:00Z 2026-02-03T02:00:00Z '[]' '{"llm": 9}' '{"llm": 9}'
tb_night 20260204T000000Z-e4f5 2026-02-04T00:00:00Z 2026-02-04T06:00:00Z "$(tb_jobs merged blocked-on-egor)" \
  '{"llm": 4, "harness": 2, "updater": 0, "code": 1}' '{"llm": 3, "harness": 2, "updater": 1, "code": 0}' \
  '{"started_at": "2026-02-04T06:00:00Z", "finished_at": null, "repos": []}'
tb_night 20260205T000000Z-abcd 2026-02-05T00:00:00Z 2026-02-05T03:30:00Z "$(tb_jobs merged)" \
  '{"llm": 2, "harness": 1, "updater": null, "code": null}' '{"llm": 0, "harness": 4, "updater": null, "code": null}' \
  '{"started_at": "2026-02-05T03:30:00Z", "finished_at": "2026-02-05T04:00:00Z", "repos": [{"repo": "/r1", "passed": 10,
    "failed": ["test_a.sh"]}, {"repo": "/r2", "passed": 5, "failed": []}]}'
jq -n '{id: "20260202T000000Z-a0b1", finished: true, hours: 9.8, runs: 3, wall_s: 36000,
  split_s: {model: 3600, slot: 7200, suite_run: 1800, suite_wait: 1800}, lines: {jobs: [10, 2, 4, 1], other: [0, 0, 0, 0]},
  rewrite: [7, 20], problems: [8, null], spend_m: 12.5, spend_kinds: {fixers: 8.0, reviews: 3.0, orchestrator: 1.5}}' \
  >"$TB/doctors/night-ledger/20260202T000000Z-a0b1.json"
jq -n '{id: "20260204T000000Z-e4f5", finished: true, hours: 6.0, runs: 2, wall_s: 0, split_s: {}, rewrite: null,
  problems: [7, 6], spend_m: 5.0}' >"$TB/doctors/night-ledger/20260204T000000Z-e4f5.json"
TZ=UTC DOCTORS_DIR="$TB/doctors" WORKER_RUN_DIR="$TB/runs" CLAUDEB_PROFILES_ROOT="$TB/profiles" \
  WORKER_STATS_DIR="$TB/stats" NIGHT_RUN_SWEEP_REPOS="$TB/sweep-repos" CHAT_NAME_ROOTS="$TB/profiles" \
  CHAT_NAMES_CACHE="$TB/chat-names.json" night report 20260205T000000Z-abcd >"$WORK/table-report" || fail "table report"
sed '/^$/,$d' "$WORK/table-report" >"$WORK/table-block"
assert [ "$(cat "$WORK/table-block")" = "                2 Feb   4 Feb   5 Feb
duration        9.8 h   6.0 h   3.5 h
spend           12.5M    5.0M    0.0M
  fixers         8.0M       –    0.0M
  reviews        3.0M       –    0.0M
  night chat     1.5M       –    0.0M
landed              2       1       1
left                1       0       0
needs Egor          0       1       0
worker runs         3       2       0
worker wall    10.0 h       –   0.0 h
model active     10 %       –       –
slot queue      2.0 h       –   0.0 h
own tests       1.0 h       –   0.0 h
problems        8 → –   7 → 6   3 → 4
  llm           5 → –   4 → 3   2 → 0
  harness       3 → –   2 → 2   1 → 4
  updater           –   0 → 1       –
  code              –   1 → 0       –
  system            –       –       –
job lines      +14/-3       –   +0/-0
rewrote 7d          7       –       –
suites ✓/✗          –       –    15/1" ]
assert [ "$(python3 -c 'import sys; print(len({len(l.rstrip("\n")) for l in sys.stdin}))' <"$WORK/table-block")" = 1 ]
assert [ "$(head -1 "$WORK/table-block" | wc -w | tr -d ' ')" = 6 ]
assert grep -qxE 'suites ✓/✗ +– +– +15/1' "$WORK/table-block"
assert_fails grep -qE '[0-9a-f]{7,}' "$WORK/table-block"
assert [ "$(body "$WORK/table-report" | head -1)" = "duration · 05 Feb 00:00 – 05 Feb 03:30 · 3.5 h" ]

# Fixture night on the per-repository count: review-bench's review-anchors/review-debt and
# claude-setup's span-off, from their checkouts (REVIEW_BENCH_ROOT, CLAUDE_SETUP_ROOT).
. "$ROOT/share/test-scope.sh"
NF_RB="${REVIEW_BENCH_ROOT:-$(git_projects "$ROOT")/review-bench}"
NF_GATE="${CLAUDE_SETUP_ROOT:-$(git_projects "$ROOT")/claude-setup}/hooks/review-flow-gate.sh"
[ -x "$NF_RB/bin/review-debt" ] && [ -f "$NF_GATE" ] || fail "fixture night needs review-bench and claude-setup checkouts"
NF="$WORK/fixture-night"
NF_REPO="$NF/drepo"
mkdir -p "$NF_REPO" "$HOME/.cache/claude/review-journal"
printf '%s\n' "$NF_REPO" >"$NF/sweep-repos"
nf() { PATH="$NF_RB/bin:/opt/homebrew/bin:$PATH" REVIEW_BENCH_BENCHES="$NF/benches" "$@"; }
nf_git() { git -C "$NF_REPO" -c user.email=t@t -c user.name=t "$@"; }
nf_debt() { nf review-debt --repo "$NF_REPO" "$@"; }
nf_aged() { GIT_AUTHOR_DATE="@$(( $(date +%s) - $1 * 86400 )) +0000" GIT_COMMITTER_DATE="@$(( $(date +%s) - $1 * 86400 )) +0000" nf_git "${@:2}"; }
nf_arm() { printf '%s words sweep\n' "$(( $(date +%s) + $1 ))" >"$HOME/.cache/claude/review-journal/span-arm-night-s1"; }
nf_span_off() { (cd "$NF_REPO" && SWEEP_REPOS_FILE="$NF/sweep-repos" nf bash "$NF_GATE" span-off night-s1); }
nf_git init -q .
seq 1 100 >"$NF_REPO/a.txt"
nf_git add -A && nf_git commit -qm base
nf review-anchors floor --repo "$NF_REPO" >/dev/null || fail "review-anchors floor"
assert [ "$(nf_debt)" = "LINES=0 FILES=0" ]
seq 1 100 >"$NF_REPO/b.txt"
seq 1 60 >"$NF_REPO/c.txt"
nf_git add -A && nf_aged 15 commit -qm landed
assert [ "$(nf_debt)" = "LINES=160 FILES=2" ]
assert [ "$(nf_debt --split)" = "LINES=160 FILES=2 DUE_LINES=160 DUE_FILES=2" ]
nf_arm 0
assert_fails nf_span_off >/dev/null 2>"$NF/refused"
assert grep -qxF "$NF_REPO LINES=160 FILES=2 DUE_LINES=160 DUE_FILES=2" "$NF/refused"
nf review-anchors anchor --repo "$NF_REPO" --kind review:20261005T010000Z-fit b.txt || fail "fit round anchor"
assert [ "$(nf_debt)" = "LINES=60 FILES=1" ]
nf review-anchors anchor --repo "$NF_REPO" --kind review:20261005T020000Z-bugs c.txt || fail "bugs round anchor"
assert [ "$(nf_debt)" = "LINES=0 FILES=0" ]
mkdir -p "$NF/benches/20261005T020000Z-bugs"
jq -n --arg d "$NF_REPO" '{repos: [{repo: $d, common_dir: ($d + "/.git"), label: "drepo"}], reviewed: {"drepo/c.txt": "x"}}' \
  >"$NF/benches/20261005T020000Z-bugs/meta.json"
nf review-anchors run-start --repo "$NF_REPO" --run claudeb-1-fix --session night-s1 || fail "fixer run-start"
seq 61 65 >>"$NF_REPO/c.txt"
assert [ "$(nf_debt)" = "LINES=5 FILES=1" ]
nf review-anchors run-fold --repo "$NF_REPO" --run claudeb-1-fix --session night-s1 \
  --round 20261005T020000Z-bugs --changed c.txt --owned c.txt || fail "fixer run-fold --round"
assert [ "$(nf_debt)" = "LINES=0 FILES=0" ]
nf_git add -A && nf_git commit -qm fix
assert [ "$(nf_debt)" = "LINES=0 FILES=0" ]
seq 1 10 >"$NF_REPO/d.txt"
nf_git add -A && nf_git commit -qm late
assert [ "$(nf_debt)" = "LINES=10 FILES=1" ]
assert nf_span_off >"$NF/closed" 2>&1
assert grep -qxF "$NF_REPO LINES=10 FILES=1 DUE_LINES=0 DUE_FILES=0" "$NF/closed"
printf '%s\n' "$NF/gone" >>"$NF/sweep-repos"
NIGHT_RUN_SWEEP_REPOS="$NF/sweep-repos" NIGHT_RUN_REVIEW_DEBT="$NF_RB/bin/review-debt" nf night report >"$NF/report" ||
  fail "fixture night report"
assert [ "$(grep '^debt now · ' "$NF/report")" = "debt now · drepo · 10 lines in 1 files · due 0 lines in 0 files
debt now · gone · unknown" ]
sed -i '' '$d' "$NF/sweep-repos"
# Fresh debt gates nothing however large, nor does an unjudged file five others source; judged critical
# (the fixture judge's verdict recorded for its content), it does.
seq 1 300 >"$NF_REPO/fresh.txt"
nf_git add -A && nf_git commit -qm fresh
nf_arm 2
assert nf_span_off >"$NF/closed" 2>&1
assert grep -qxF "$NF_REPO LINES=310 FILES=2 DUE_LINES=0 DUE_FILES=0" "$NF/closed"
seq 1 200 >"$NF_REPO/lib.sh"
for n in 1 2 3 4 5; do printf '. "$(dirname "$0")/lib.sh"\n' >"$NF_REPO/use$n.sh"; done
nf_git add -A && nf_git commit -qm critical
nf_arm 4
assert nf_span_off >"$NF/closed" 2>&1
assert grep -qxF "$NF_REPO LINES=515 FILES=8 DUE_LINES=0 DUE_FILES=0" "$NF/closed"
jq -cn --arg b "$(nf_git rev-parse HEAD:lib.sh)" '{path: "lib.sh", blob: $b, critical: true, reason: "fixture judge"}' |
  nf review-debt --repo "$NF_REPO" --record-critical >/dev/null
nf_arm 6
assert_fails nf_span_off >/dev/null 2>"$NF/refused"
assert grep -qxF "$NF_REPO LINES=515 FILES=8 DUE_LINES=200 DUE_FILES=1" "$NF/refused"

# survey: the sweep's opening lines for any repository, in the sweep list or not: the debt and the chunk
# column off review-bench's price, keep/take off the leftovers' live and held signals; --post sends it,
# and report --post its comparison table, to the chat as one report-bus block each.
SV="$WORK/survey-repos"
sv() { GIT_COMMITTER_DATE='2026-01-01T00:00:00Z' git -c user.name=t -c user.email=t@t -C "$@"; }
git init -q -b main "$SV/repo"
printf 'a\n' >"$SV/repo/a" && sv "$SV/repo" add a && sv "$SV/repo" commit -qm a
sv "$SV/repo" worktree add -q -b feat/old "$SV/old"
printf 'b\n' >"$SV/old/b" && sv "$SV/old" add b && sv "$SV/old" commit -qm b
printf 'w\n' | tee "$SV/old/w1" >"$SV/old/w2" && touch -t 202601010000 "$SV/old/w1" "$SV/old/w2"
sv "$SV/repo" commit -q --allow-empty -m c && sv "$SV/repo" commit -q --allow-empty -m d
git -C "$SV/repo" worktree add -q -b fresh "$SV/fresh"
(cd "$SV/fresh" && exec sleep 600) >/dev/null 2>&1 &
printf '%s\n' "$!" >>"$DATA/orchestrators"
git -C "$SV/repo" worktree add -q -b frozen "$SV/frozen"
git -C "$SV/repo" worktree lock "$SV/frozen"
sleep 0.5
: >"$SV/repo/untracked"
cat >"$DATA/price" <<EOF
  repo/ = $SV/repo: 1111111..2222222 · 3 file(s) · 40 line(s) · scope: a
  old/ = $SV/old: 3333333..4444444 · 1 file(s) · 12 line(s) · scope: b
  2 chunks over these repositories
  repo · 3 file(s) · 40 line(s) · 900 KB · 2 chunk(s)
  old · 1 file(s) · 12 line(s) · 1 KB · whole
total · 4 file(s) · 52 line(s) · 901 KB · 2 chunk(s) (past the 800 KB gate, passes run side by side)
EOF
cat >"$FAKE_BIN/report-bus" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$DATA/bus-args"
jq -c . >>"$DATA/bus-docs"
EOF
chmod +x "$FAKE_BIN/report-bus"
export NIGHT_RUN_REPORT_BUS="$FAKE_BIN/report-bus"
cat >"$DATA/price-due" <<EOF
  repo/ = $SV/repo: 1111111..2222222 · 1 file(s) · 30 line(s) · scope: a
  repo · 1 file(s) · 30 line(s) · 1 KB · whole
total · 1 file(s) · 30 line(s) · 1 KB · whole
EOF
night survey "$SV/repo" >"$WORK/survey.out" || fail "survey"
assert [ "$(cat "$WORK/survey.out")" = "repo · debt 40 lines/3 files · due 30 lines/1 files · 1 dirty · 2 chunks
  fresh · +0/-0 main · 0 dirty · debt 0 · take (landed)
  frozen · +0/-0 main · 0 dirty · debt 0 · keep (locked)
  feat/old · +1/-2 main · 2 dirty · debt 12 · take (unlanded commits)
total · debt 52 lines/4 files · due 30 lines/1 files · 3 dirty · 2 chunks" ]
assert [ "$(cat "$DATA/price-args")" = "review --debt --repo $SV/repo --tier T2 --price
review --debt --due --repo $SV/repo --tier T2 --price" ]
assert [ ! -e "$DATA/bus-docs" ]
night survey --post "$SV/repo" | cmp -s - "$WORK/survey.out" || fail "survey --post prints the same lines"
assert grep -qE '^post --kind notice --id night-survey-[0-9]+-[0-9]+$' "$DATA/bus-args"
assert jqe '.word == "survey" and .rows == [["repo", ["debt 40 lines/3 files", "due 30 lines/1 files · 1 dirty · 2 chunks"]],
  ["  fresh", ["+0/-0 main · 0 dirty · debt 0", "take (landed)"]],
  ["  frozen", ["+0/-0 main · 0 dirty · debt 0", "keep (locked)"]],
  ["  feat/old", ["+1/-2 main · 2 dirty · debt 12", "take (unlanded commits)"]],
  ["total", ["debt 52 lines/4 files", "due 30 lines/1 files · 3 dirty · 2 chunks"]]]' "$DATA/bus-docs"
python3 "$ROOT/share/report_frame.py" block <"$DATA/bus-docs" >/dev/null || fail "the survey block renders"
rm "$DATA/bus-docs" "$DATA/bus-args"
night report --post >"$WORK/report-post" || fail "report --post"
assert [ "$(head -1 "$WORK/report-post")" = 'table · posted to the chat as the night block; the final message does not retype it' ]
night report | sed '1,/^$/d' | cmp -s - <(sed '1,/^$/d' "$WORK/report-post") || fail "report --post prints the rest of the report"
assert [ "$(wc -l <"$DATA/bus-docs" | tr -d " ")" = 1 ]
night report >"$WORK/report" || fail "report"
table=$(sed '/^$/q' "$WORK/report")
assert jqe --arg w "night · $(head -1 <<<"$table" | sed -E 's/.* {3,}//')" \
  --argjson labels "$(sed '1d;/^$/d' <<<"$table" | sed -E 's/ {3,}.*//' | jq -Rsc 'split("\n")[:-1]')" \
  '.word == $w and .rows[0][0] == "" and [.rows[1:][][0]] == $labels
   and ([.rows[][1] | length] | unique | length) == 1' "$DATA/bus-docs"
assert grep -qE '^post --kind notice --id night-report-[0-9]+-[0-9]+$' "$DATA/bus-args"
rendered=$(python3 "$ROOT/share/report_frame.py" block <"$DATA/bus-docs") || fail "the report block renders"
assert [ "$(wc -l <<<"$rendered" | tr -d ' ')" = "$(($(jq '.rows | length' "$DATA/bus-docs") + 2))" ]
unset NIGHT_RUN_REPORT_BUS

# Speed window: a Speed fixer's first start past 6 h of the night's start leaves its job and abandons its
# run, never a sibling lever's; one started inside it passes again later, and any other fixer is never gated. A night without a
# Speed run has no speed line.
assert_fails grep -q '^speed · ' "$WORK/report"
speed_night() { # id hours-ago job-ref...
  jq -n --arg id "$1" --argjson h "$2" '{id: $id, started_at: (now - $h * 3600 | floor | todate), finished_at: null,
    jobs: [$ARGS.positional[] | {kind: "fixer", ref: ., state: "pending", reason: null, branch: null, review: null,
    commits: [], pushed: false}]}' --args "${@:3}" >"$(record "$1")"
}
speed_run() { # ref area problems
  jq -n --arg id "$1" --arg a "$2" --argjson n "$3" '{id: $id, doctor: "harness", area: $a, launched_at: "2026-10-07T00:00:00Z",
    closed_at: null, abandoned_at: null, failed_at: null, note: null, problems: [range($n) | {id: "p\(.)"}]}' >"$DOCTORS_DIR/runs/$1.json"
}
speed_run hs-late speed-tests-a 3; speed_run hs-early speed 2; speed_run hs-other speed-chat-hooks 1
speed_run hs-in speed-chat-tests 4; speed_run hh-late hooks 1
speed_night nlate 7 hs-late hs-early hs-other hh-late
jq '.events = [{id: 1, phase: "speed-start", job: "hs-early"}]' "$(record nlate)" >"$WORK/tmp" && mv "$WORK/tmp" "$(record nlate)"
speed_night nopen 1 hs-in
rc=0; night speed-gate nlate hs-late >"$WORK/out" 2>&1 || rc=$?
assert [ "$rc" = 3 ]
assert grep -qxF "speed window closed (6 h): night nlate job hs-late left, its fixer not started" "$WORK/out"
assert jqe '.jobs[0].state == "left" and .jobs[0].reason == "speed window closed (6 h)"' "$(record nlate)"
assert jqe '.abandoned_at != null and .note == "speed window closed (6 h)"' "$DOCTORS_DIR/runs/hs-late.json"
assert jqe '[.jobs[1:][] | .state] == ["pending", "pending", "pending"]' "$(record nlate)"
assert jqe '.abandoned_at == null' "$DOCTORS_DIR/runs/hs-other.json"
night speed-gate nlate hs-early || fail "a Speed fixer started inside the window was refused on its resume"
night speed-gate nlate hh-late || fail "a non-speed fixer was gated by the speed window"
assert jqe '[.jobs[1:][] | .state] == ["pending", "pending", "pending"] and ([.events[] | select(.phase == "speed-start")] | length) == 1' "$(record nlate)"
assert jqe '.abandoned_at == null' "$DOCTORS_DIR/runs/hh-late.json"
rc=0; night speed-gate nlate hs-other >/dev/null 2>&1 || rc=$?
assert [ "$rc" = 3 ]
assert jqe '[.jobs[] | .state] == ["left", "pending", "left", "pending"]' "$(record nlate)"
night speed-gate nopen hs-in || fail "a Speed fixer inside the window was refused"
night speed-gate nopen hs-in || fail "a started Speed fixer was refused again"
assert jqe '.jobs[0].state == "pending" and [.events[] | select(.phase == "speed-start") | .job] == ["hs-in"]' "$(record nopen)"
night report nlate >"$WORK/report" || fail "report of the speed night"
assert grep -qxF "speed · levers 6 selected · 2 started · 4 left by the 6 h window" "$WORK/report"
night report nopen >"$WORK/report" || fail "report of the open speed night"
assert grep -qxF "speed · levers 4 selected · 4 started · 0 left by the 6 h window" "$WORK/report"
rm "$(record nlate)" "$(record nopen)"

# No night at all: the menu prints nothing.
rm "$NIGHTS"/*.json
assert [ -z "$(night latest --menu)" ]
assert_fails night report 2>/dev/null

# Trades: when answer= is set and before a night starts, every answered trade (a blocked-on-egor job) is re-checked.
# Carried out, it settles with its evidence; not carried out, it becomes a trade job of the new night; never
# answered, it stays. Answers are recorded ones only: answer= with its done= checks, or a handoff doc settled,
# found by the job's path or, on a job from before paths, by its ref's slug.
TR="$WORK/trades"
git init -q -b main "$TR"
git -C "$TR" -c user.name=t -c user.email=t@t commit -q --allow-empty -m root
done_hash=$(git -C "$TR" rev-parse HEAD)
undone_hash=$(git -C "$TR" -c user.name=t -c user.email=t@t commit-tree "$(git -C "$TR" rev-parse 'HEAD^{tree}')" -p HEAD -m side)
mkdir -p "$TR/docs/handoffs"
printf '# S\n\nStatus: settled 2026-10-07: Egor agreed to keep it\n' >"$TR/docs/handoffs/s.md"
printf '# O\n\nStatus: trade for Egor\nCost: c.\nLoss: l.\nRecommendation: r.\n' >"$TR/docs/handoffs/o.md"
printf '%s\n' "$TR" >"$WORK/sweep-repos"
trade() { jq -nc --arg k "$1" --arg r "$2" --arg p "${3:-}" '{kind: $k, ref: $r, state: "blocked-on-egor",
  reason: "Cost: c. Loss: l. Recommendation: r.", branch: null, review: null, commits: [], pushed: false}
  + (if $p == "" then {} else {path: $p} end)'; }
jq -n --argjson j "[$(trade fixer t-done), $(trade fixer t-todo), $(trade fixer t-bare), $(trade handoff t-doc "$TR/docs/handoffs/s.md"),
  $(trade handoff t-open "$TR/docs/handoffs/o.md"), $(trade fixer t-none), $(trade handoff handoff-s)]" \
  '{id: "tn", started_at: "2026-01-02T00:00:00Z", finished_at: "2026-01-02T03:00:00Z", session: null, jobs: $j}' >"$(record tn)"
night job tn set t-done "answer=merge it" "done=commit:trades:$done_hash,file:$TR/docs/handoffs/o.md,gone:$TR/nothing" >"$WORK/out" ||
  fail "answer with checks"
assert grep -qxF "trade tn t-done settled: commit trades@$done_hash on main; file $TR/docs/handoffs/o.md exists; file $TR/nothing is gone" "$WORK/out"
night job tn set t-todo "answer=raise it" "done=commit:trades:$undone_hash" >"$WORK/out" || fail "answer not carried out"
assert [ "$(grep -c '^trade ' "$WORK/out")" = 0 ]
night job tn set t-bare "answer=look at it" >/dev/null || fail "answer without checks"
assert_fails night job tn set t-none done=keep 2>"$WORK/err"
assert grep -qF 'done= comes with answer=' "$WORK/err"
assert_fails night job tn set t-none answer=x done=maybe 2>/dev/null
night job tn add debt d1 >/dev/null
assert_fails night job tn set d1 answer=x 2>"$WORK/err"
assert grep -qF 'not blocked-on-egor' "$WORK/err"
assert jqe '(.jobs[0].answer | .words == "merge it" and (.done | length) == 3 and .at != null and .by != null)
  and .jobs[2].answer.done == [] and (.jobs[5] | has("answer") | not)' "$(record tn)"
night start >"$WORK/out" || fail "start with trades"
tid=$(sed -n 's/^night \([^ ]*\) started:.*/\1/p' "$WORK/out")
assert grep -qxF "trade tn t-doc settled: $TR/docs/handoffs/s.md: Status: settled 2026-10-07: Egor agreed to keep it" "$WORK/out"
assert grep -qxF "trade tn t-todo -> trade-t-todo" "$WORK/out"
assert grep -qxF "trade tn t-bare -> trade-t-bare" "$WORK/out"
assert grep -qxF "trade tn handoff-s settled: $TR/docs/handoffs/s.md: Status: settled 2026-10-07: Egor agreed to keep it" "$WORK/out"
assert [ "$(grep -c '^trade ' "$WORK/out")" = 4 ]
assert jqe --arg n "$tid" '[.jobs[] | [.ref, .state, (.settled.night // null), (.carried.ref // null)]] == [
    ["t-done", "settled", "tn", null], ["t-todo", "blocked-on-egor", null, "trade-t-todo"],
    ["t-bare", "blocked-on-egor", null, "trade-t-bare"], ["t-doc", "settled", $n, null],
    ["t-open", "blocked-on-egor", null, null], ["t-none", "blocked-on-egor", null, null], ["handoff-s", "settled", $n, null],
    ["d1", "pending", null, null]]
  and .jobs[0].settled.evidence[0] == "commit trades@'"$done_hash"' on main"
  and [.events[] | select(.phase | startswith("trade-")) | [.phase, .job, .night]] == [["trade-settled", "t-done", "tn"],
    ["trade-carried", "t-todo", $n], ["trade-carried", "t-bare", $n], ["trade-settled", "t-doc", $n], ["trade-settled", "handoff-s", $n]]' "$(record tn)"
assert jqe --arg n "$tid" '[.jobs[] | [.kind, .ref, .state, .branch, .answer.words, .from.night, .from.ref, .from.trade]] == [
    ["trade", "trade-t-todo", "pending", "night/\($n)/trade-t-todo", "raise it", "tn", "t-todo", "Cost: c. Loss: l. Recommendation: r."],
    ["trade", "trade-t-bare", "pending", "night/\($n)/trade-t-bare", "look at it", "tn", "t-bare", "Cost: c. Loss: l. Recommendation: r."]]
  and [.events[] | select(.phase == "add") | .job] == ["trade-t-todo", "trade-t-bare"]' "$(record "$tid")"
night report tn >"$WORK/report" || fail "report of the trade night"
assert grep -qF "settled · fixer · t-done · Cost: c. Loss: l. Recommendation: r. · settled by night tn: commit trades@" "$WORK/report"
assert grep -qxF "blocked-on-egor · fixer · t-todo · Cost: c. Loss: l. Recommendation: r. · answered, carried to night $tid as trade-t-todo" "$WORK/report"
assert grep -qxF "total · 4 blocked-on-egor · 3 settled · 1 pending" "$WORK/report"
# Carried or never answered, no trade moves at the next start.
stop_chat "$(jq -r .session "$(record "$tid")")"
night start >"$WORK/out" || fail "start after the trades moved"
assert [ "$(grep -c '^trade ' "$WORK/out")" = 0 ]
assert jqe '[.jobs[] | select(.carried != null) | .ref] == ["t-todo", "t-bare"]' "$(record tn)"
stop_chat "$(jq -r .session "$(record "$(sed -n 's/^night \([^ ]*\) started:.*/\1/p' "$WORK/out")")")"
# A carried trade blocked on Egor again asks a new question: the answer it carried answers none of it.
night job "$tid" set trade-t-todo state=blocked-on-egor "reason=Cost: c2. Loss: l2. Recommendation: r2." >/dev/null ||
  fail "a carried trade blocked again"
assert jqe '.jobs[] | select(.ref == "trade-t-todo") | .answer == null' "$(record "$tid")"
night start >"$WORK/out" || fail "start after a carried trade blocked again"
assert [ "$(grep -c '^trade ' "$WORK/out")" = 0 ]
stop_chat "$(jq -r .session "$(record "$(sed -n 's/^night \([^ ]*\) started:.*/\1/p' "$WORK/out")")")"
# A new night whose chat did not open hands the trades it carried back to their nights.
jq -n --argjson j "[$(trade fixer t-back)]" '{id: "tf", started_at: "2026-01-02T05:00:00Z", finished_at: "2026-01-02T06:00:00Z",
  session: null, jobs: $j}' >"$(record tf)"
night job tf set t-back "answer=do it" "done=commit:trades:$undone_hash" >/dev/null || fail "answer t-back"
touch "$DATA/opener-fails"
assert_fails night start 2>/dev/null
rm "$DATA/opener-fails"
assert jqe '.jobs[0] | has("carried") | not' "$(record tf)"
assert jqe '[.[] | select((.note // "") | startswith("orchestrator chat did not open")) | .jobs] == [[]]' <(jq -s . "$NIGHTS"/*.json)

# Each merged job records the commits its own branch made, as landed on main, whatever the orchestrator lists:
# two jobs landed through one integration commit (2026-10-07: night 7777 gave eight fixers its fea660fb) each
# report their own hashes and lines, the integration commit only as integration, day work on main as neither.
OC="$WORK/own"
oc() { git -C "$1" -c user.name=t -c user.email=t@t "${@:2}"; }
git init -q -b main "$OC"
oc "$OC" commit -q --allow-empty -m root
printf '%s\n' "$OC" >"$WORK/sweep-repos"
jq -n '{id: "on", started_at: "2026-01-03T00:00:00Z", finished_at: null, session: null, jobs: []}' >"$(record on)"
git -C "$OC" update-ref refs/night/on/base HEAD
for j in ja jb; do
  night job on add fixer "$j" --branch "night/on/$j" >/dev/null
  git -C "$OC" worktree add -q -b "night/on/$j" "$WORK/own-$j" refs/night/on/base
done
printf 'a\nb\n' >"$WORK/own-ja/a.txt" && oc "$WORK/own-ja" add a.txt && oc "$WORK/own-ja" commit -qm 'ja work'
printf '1\n2\n3\n' >"$WORK/own-jb/b.txt" && oc "$WORK/own-jb" add b.txt && oc "$WORK/own-jb" commit -qm 'jb work'
printf 'x\n' >"$WORK/own-jb/c.txt" && oc "$WORK/own-jb" add c.txt && oc "$WORK/own-jb" commit -qm 'jb more'
printf 'd\n' >"$OC/day.txt" && oc "$OC" add day.txt && oc "$OC" commit -qm 'day work'
oc "$WORK/own-ja" rebase -q main && git -C "$OC" merge -q --ff-only night/on/ja || fail "ja did not land"
oc "$OC" cherry-pick refs/night/on/base..night/on/jb >/dev/null || fail "jb did not land"
printf 'a\nB\n' >"$OC/a.txt" && printf '1\n2\n3\n4\n' >"$OC/b.txt" && oc "$OC" commit -qam 'integration'
integ=$(git -C "$OC" rev-parse HEAD)
ja=$(git -C "$OC" rev-parse night/on/ja) jb1=$(git -C "$OC" rev-parse HEAD~2) jb2=$(git -C "$OC" rev-parse HEAD~1)
assert [ "$(git -C "$OC" log -1 --format=%s "$jb1") $(git -C "$OC" log -1 --format=%s "$jb2")" = "jb work jb more" ]
night job on set ja state=merged "commits=own:${integ:0:8}" >/dev/null || fail "ja merged"
night job on set jb state=merged "commits=own:$integ" >/dev/null || fail "jb merged"
assert jqe --arg ja "$ja" --arg b1 "$jb1" --arg b2 "$jb2" --arg i "$integ" '[.jobs[] | [.ref, .commits, .integration]] == [
  ["ja", [{repo: "own", hash: $ja}], [{repo: "own", hash: $i}]],
  ["jb", [{repo: "own", hash: $b1}, {repo: "own", hash: $b2}], [{repo: "own", hash: $i}]]]' "$(record on)"
night report on >"$WORK/report" || fail "report of the integration night"
assert grep -qxF "landed · fixer · ja · own@${ja:0:7} · integration own@${integ:0:7} · code +2/-0 · not pushed" "$WORK/report"
assert grep -qxF "landed · fixer · jb · own@${jb1:0:7} · own@${jb2:0:7} · integration own@${integ:0:7} · code +4/-0 · not pushed" "$WORK/report"
# Setting it again keeps the integration list; a job whose branch is gone keeps what it is given.
night job on set ja state=merged >/dev/null || fail "ja merged again"
assert jqe --arg i "$integ" '.jobs[0].integration == [{repo: "own", hash: $i}]' "$(record on)"
night job on add fixer jc --branch night/on/jc >/dev/null
night job on set jc state=merged "commits=own:$integ" >/dev/null || fail "jc merged"
assert jqe --arg i "${integ}" '.jobs[2].commits == [{repo: "own", hash: $i}] and (.jobs[2] | has("integration") | not)' "$(record on)"
# A branch hash recorded before its landing rebased it is the job's own commit, never integration.
night job on add fixer jd --branch night/on/jd >/dev/null
git -C "$OC" worktree add -q -b night/on/jd "$WORK/own-jd" refs/night/on/base
printf 'e\n' >"$WORK/own-jd/e.txt" && oc "$WORK/own-jd" add e.txt && oc "$WORK/own-jd" commit -qm 'jd work'
jd_branch=$(git -C "$OC" rev-parse night/on/jd)
night job on set jd "commits=own:$jd_branch" >/dev/null || fail "jd commits from the report"
oc "$WORK/own-jd" rebase -q main && git -C "$OC" merge -q --ff-only night/on/jd || fail "jd did not land"
jd=$(git -C "$OC" rev-parse night/on/jd)
assert [ "$jd" != "$jd_branch" ]
night job on set jd state=merged >/dev/null || fail "jd merged"
assert jqe --arg h "$jd" '.jobs[3].commits == [{repo: "own", hash: $h}] and .jobs[3].integration == []' "$(record on)"
# A commit the branch got by cherry-pick is its own too.
night job on add fixer je --branch night/on/je >/dev/null
git -C "$OC" worktree add -q -b night/on/je "$WORK/own-je" refs/night/on/base
oc "$WORK/own-je" checkout -q -b je-side && printf 'f\n' >"$WORK/own-je/f.txt" && oc "$WORK/own-je" add f.txt && oc "$WORK/own-je" commit -qm 'je work'
oc "$WORK/own-je" checkout -q night/on/je && oc "$WORK/own-je" cherry-pick je-side >/dev/null || fail "je cherry-pick"
night job on set je state=merged >/dev/null || fail "je merged"
assert jqe --arg h "$(git -C "$OC" rev-parse night/on/je)" '.jobs[4].commits == [{repo: "own", hash: $h}]' "$(record on)"

# finish keeps a landed worktree holding ignored files besides caches: removing it would delete them.
PI="$WORK/prune"
git init -q -b main "$PI" && oc "$PI" commit -q --allow-empty -m root
printf '.env\n__pycache__/\n.claude/\n' >>"$PI/.git/info/exclude"
printf '%s\n' "$PI" >"$WORK/sweep-repos"
for b in keeps cache; do git -C "$PI" worktree add -q -b "$b" "$PI/.claude/worktrees/$b" main; done
printf 's\n' >"$PI/.claude/worktrees/keeps/.env"
mkdir "$PI/.claude/worktrees/cache/__pycache__" && : >"$PI/.claude/worktrees/cache/__pycache__/x.pyc"
jq -n '{id: "pi", started_at: "2026-01-04T00:00:00Z", finished_at: null, session: null, jobs: []}' >"$(record pi)"
night finish pi >"$WORK/out" || fail "finish with ignored files"
assert grep -qxF "live prune keeps: it holds ignored files (.env)" "$WORK/out"
assert grep -qxF "pruned prune cache" "$WORK/out"
assert [ "$(cat "$PI/.claude/worktrees/keeps/.env")" = s ]

echo "PASS: test_night_run.sh ($asserts asserts)"
