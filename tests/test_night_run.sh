#!/usr/bin/env bash
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
WORK="$(cd -P "$WORK" && pwd)"
asserts=0
fail() { echo "FAIL: $*" >&2; exit 1; }
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
export DOCTORS_DIR="$WORK/doctors" LLM_DOCTOR_DIR="$WORK/llm" HARNESS_DOCTOR_DIR="$WORK/harness" \
  UPDATER_DOCTOR_DIR="$WORK/updater" NIGHT_RUN_OPENER="$FAKE_BIN/opener" NIGHT_RUN_WORKER_PICK="$FAKE_BIN/worker-pick" \
  NIGHT_RUN_SWEEP_REPOS="$WORK/sweep-repos"
PATH="$FAKE_BIN:/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin:/usr/local/bin"
mkdir -p "$FAKE_BIN" "$DATA" "$HOME" "$WORK/llm" "$WORK/harness" "$WORK/updater"
: >"$OPENED"
cat >"$FAKE_BIN/opener" <<'EOF'
#!/usr/bin/env bash
[ ! -e "$DATA/opener-fails" ] || exit 1
printf '%s\n' "$*" >>"$OPENED"
EOF
printf '#!/usr/bin/env bash\nprintf "%%s\\n" "$*" >>"$DATA/pick-args"\nprintf "acct-n\\n"\n' >"$FAKE_BIN/worker-pick"
printf '#!/usr/bin/env bash\nexit 0\n' >"$FAKE_BIN/claudeb"
chmod +x "$FAKE_BIN"/*

night() { bash "$ROOT/bin/night-run" "$@"; }
record() { printf '%s/%s.json' "$NIGHTS" "$1"; }
doc() { jq -n --argjson n "$2" '{contract: 1, problem_count: $n}' >"$WORK/$1/latest.json"; }
doc llm 5
doc harness 3

# start: the record, the orchestrator chat on the main checkout with the sweep word, the session.
night start >"$WORK/out" || fail "start failed"
id=$(sed -n 's/^night \([0-9]\{8\}T[0-9]\{6\}Z-[0-9a-f]\{4\}\) started: orchestrator on acct-n, deadline .*/\1/p' "$WORK/out")
assert [ -n "$id" ]
R=$(record "$id")
assert jqe 'keys == (["id", "started_at", "deadline_at", "finished_at", "session", "account", "command", "note",
  "doctors_before", "doctors_after", "jobs"] | sort)' "$R"
assert jqe '.doctors_before == {llm: 5, harness: 3, updater: null} and .doctors_after == null and .jobs == []
  and .finished_at == null and .account == "acct-n"' "$R"
assert jqe '((.deadline_at | fromdateiso8601) - (.started_at | fromdateiso8601)) == 4 * 3600' "$R"
session=$(jq -r .session "$R")
assert [ "${#session}" = 36 ]
assert [ "$(cat "$OPENED")" = "$NIGHTS/$id.command" ]
assert jqe --arg c "$NIGHTS/$id.command" '.command == $c' "$R"
main=$(dirname "$(git -C "$ROOT" rev-parse --path-format=absolute --git-common-dir)")
assert grep -qF "cd $main " "$NIGHTS/$id.command"
assert grep -qF -- "--session-id $session " "$NIGHTS/$id.command"
exec_line=$(grep '^exec ' "$NIGHTS/$id.command")
eval "set -- ${exec_line#exec }"
assert [ "${!#}" = "сделай чистку — night run $id" ]
assert [ "$1 $2" = "caffeinate -i" ]
assert grep -qxF -- '--account claudeb --role chat --claim' "$DATA/pick-args"

# An open night refuses a second start; one past its deadline does not.
assert_fails night start 2>"$WORK/err"
assert grep -qF "night $id is still open" "$WORK/err"
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
night job "$id" set debt-round state=left "reason=deadline: 140 lines left" >/dev/null || fail "set left"
night job "$id" set harness-r1 state=failed-launch reason=opener >/dev/null || fail "set failed"
assert jqe '.jobs[2].state == "left" and .jobs[2].reason == "deadline: 140 lines left"' "$R"

# pushed=true is checked against the remote.
git init -q --bare "$WORK/origin.git"
git init -q -b main "$WORK/repo"
git -C "$WORK/repo" -c user.name=t -c user.email=t@t commit -q --allow-empty -m one
git -C "$WORK/repo" remote add origin "$WORK/origin.git"
git -C "$WORK/repo" push -q origin main
pushed_hash=$(git -C "$WORK/repo" rev-parse HEAD)
git -C "$WORK/repo" -c user.name=t -c user.email=t@t commit -q --allow-empty -m two
local_hash=$(git -C "$WORK/repo" rev-parse HEAD)
printf '%s\n' "$WORK/elsewhere/llm-legs" "$WORK/repo" >"$WORK/sweep-repos"
assert_fails night job "$id" set llm-20260930T010203Z pushed=true 2>"$WORK/err"
assert grep -qF 'needs the job' "$WORK/err"
night job "$id" set llm-20260930T010203Z state=merged "commits=repo:$local_hash" review=rb-1 >/dev/null || fail "set merged"
assert_fails night job "$id" set llm-20260930T010203Z pushed=true 2>"$WORK/err"
assert grep -qF "commit $local_hash is not on origin" "$WORK/err"
assert jqe '.jobs[0].pushed == false and .jobs[0].commits == [{repo: "repo", hash: "'"$local_hash"'"}]
  and .jobs[0].review == "rb-1"' "$R"
assert_fails night job "$id" set llm-20260930T010203Z "commits=nowhere:$pushed_hash" pushed=true 2>"$WORK/err"
assert grep -qF 'no repository nowhere' "$WORK/err"
night job "$id" set llm-20260930T010203Z "commits=repo:$pushed_hash" pushed=true >/dev/null || fail "pushed by name"
night job "$id" set codex-e1 state=merged "commits=$WORK/repo:$pushed_hash" pushed=true >/dev/null || fail "pushed by path"
assert jqe '.jobs[0].pushed == true and .jobs[1].pushed == true' "$R"
night job "$id" set p1 state=blocked-on-egor reason="step 10 needs his word" >/dev/null || fail "set blocked"

# Menu and report while running.
IFS=$'\t' read -r text red < <(night latest --menu)
assert [ "$text" = 'Night: running · 2 merged · 1 left · 1 failed · 1 blocked on Egor · 7 pending · pushed' ]
assert [ "$red" = 1 ]

# finish: doctors after, pending becomes left with a reason; a second finish refuses.
doc llm 1
doc harness 0
doc updater 2
night finish "$id" >/dev/null || fail "finish"
assert_fails night finish "$id" 2>/dev/null
assert jqe '.doctors_after == {llm: 1, harness: 0, updater: 2} and .finished_at != null
  and ([.jobs[] | select(.state == "pending")] | length) == 0
  and ([.jobs[] | select(.ref == "p2")][0] | .state == "left" and .reason == "no outcome recorded by the close")' "$R"
night report "$id" >"$WORK/report" || fail "report"
assert grep -qxF "doctors · llm 5→1 · harness 3→0 · updater -→2" "$WORK/report"
assert grep -qxF "merged · fixer · llm-20260930T010203Z · review rb-1 · repo@${pushed_hash:0:7} · pushed" "$WORK/report"
assert grep -qxF "left · debt · debt-round · deadline: 140 lines left" "$WORK/report"
assert grep -qxF "failed-launch · fixer · harness-r1 · night/$id/harness-r1 · opener" "$WORK/report"
assert grep -qxF "total · 2 merged · 8 left · 1 failed-launch · 1 blocked-on-egor · pushed" "$WORK/report"
assert [ "$(wc -l <"$WORK/report" | tr -d ' ')" = 15 ]
assert [ "$(awk '{ print length }' "$WORK/report" | sort -n | tail -1)" -le 100 ]
assert cmp -s "$WORK/report" <(night report)
jq '.started_at = "2026-01-01T00:00:00Z"' "$R" >"$WORK/tmp" && mv "$WORK/tmp" "$R"

# A clean night reads green; a merged job not pushed turns it red.
night start --deadline-h 2 >"$WORK/out" || fail "second start"
id2=$(sed -n 's/^night \([^ ]*\) started:.*/\1/p' "$WORK/out")
R2=$(record "$id2")
assert jqe '((.deadline_at | fromdateiso8601) - (.started_at | fromdateiso8601)) == 2 * 3600' "$R2"
night job "$id2" add fixer f1 >/dev/null
night job "$id2" add vendor v1 >/dev/null
night job "$id2" set f1 state=merged "commits=repo:$pushed_hash" pushed=true >/dev/null
night job "$id2" set v1 state=nothing-to-do >/dev/null
night finish "$id2" >/dev/null
assert [ "$(night latest --menu)" = "$(printf 'Night: 1 merged · pushed\t0')" ]
night report | head -1 | grep -q "^night $id2 " || fail "report without an id reads the latest night"
night job "$id2" set v1 state=merged "commits=repo:$local_hash" >/dev/null
assert [ "$(night latest --menu)" = "$(printf 'Night: 2 merged · 1 not pushed\t1')" ]

# A night past its deadline and never finished no longer blocks start, and reads red.
night start >"$WORK/out" || fail "third start"
id3=$(sed -n 's/^night \([^ ]*\) started:.*/\1/p' "$WORK/out")
jq '.started_at = "2026-01-01T00:00:00Z" | .deadline_at = "2026-01-01T01:00:00Z"' "$(record "$id3")" >"$WORK/tmp" &&
  mv "$WORK/tmp" "$(record "$id3")"
night start >"$WORK/out" || fail "start after a lapsed deadline"
id4=$(sed -n 's/^night \([^ ]*\) started:.*/\1/p' "$WORK/out")
rm "$(record "$id")" "$(record "$id2")" "$(record "$id4")"
IFS=$'\t' read -r text red < <(night latest --menu)
assert [ "$text" = 'Night: unfinished · no jobs' ]
assert [ "$red" = 1 ]

# The chat does not open: the night is closed with a note and reads red.
rm "$(record "$id3")"
touch "$DATA/opener-fails"
assert_fails night start 2>"$WORK/err"
assert grep -qF 'the orchestrator chat did not open' "$WORK/err"
id5=$(ls "$NIGHTS" | sed -n 's/\.json$//p' | head -1)
assert jqe '.finished_at != null and (.note | startswith("orchestrator chat did not open"))' "$(record "$id5")"
IFS=$'\t' read -r text red < <(night latest --menu)
assert [ "$text" = 'Night: no jobs' ]
assert [ "$red" = 1 ]
rm "$DATA/opener-fails"
night start >/dev/null || fail "a failed open does not block the next start"

# base: every sweep repository is snapshotted as it stands (uncommitted and untracked included)
# into refs/night/<id>/base, without touching its index or working tree.
git init -q -b main "$WORK/snap"
git -C "$WORK/snap" -c user.email=t@t -c user.name=t commit -q --allow-empty -m root
printf 'committed\n' >"$WORK/snap/a"
git -C "$WORK/snap" add a
git -C "$WORK/snap" -c user.email=t@t -c user.name=t commit -q -m a
printf 'dirty\n' >"$WORK/snap/a"
printf 'new\n' >"$WORK/snap/untracked"
printf '%s\n' "$WORK/snap" >"$WORK/sweep-repos"
id6=$(ls -t "$NIGHTS" | sed -n 's/\.json$//p' | head -1)
before_status=$(git -C "$WORK/snap" status --porcelain)
night base "$id6" >"$WORK/base.out" || fail "night base failed"
assert [ "$(git -C "$WORK/snap" show "refs/night/$id6/base:a")" = dirty ]
assert [ "$(git -C "$WORK/snap" show "refs/night/$id6/base:untracked")" = new ]
assert [ "$(git -C "$WORK/snap" rev-parse "refs/night/$id6/base^")" = "$(git -C "$WORK/snap" rev-parse HEAD)" ]
assert [ "$(git -C "$WORK/snap" status --porcelain)" = "$before_status" ]
assert jqe --arg c "$(git -C "$WORK/snap" rev-parse "refs/night/$id6/base")" '.bases.snap == $c' "$(record "$id6")"
night finish "$id6" >/dev/null

# No night at all: the menu prints nothing.
rm "$NIGHTS"/*.json
assert [ -z "$(night latest --menu)" ]
assert_fails night report 2>/dev/null

echo "PASS: test_night_run.sh ($asserts asserts)"
