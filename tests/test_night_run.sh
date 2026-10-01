#!/usr/bin/env bash
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK="$(mktemp -d)"
trap 'xargs kill 2>/dev/null <"$WORK/data/orchestrators"; rm -rf "$WORK"' EXIT
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
session=$(LC_ALL=C sed -n 's/.*--session-id \([^ ]*\) .*/\1/p' "$1")
bash -c 'exec -a "$0" sleep 600' "claudeb profile acct-n --session-id $session" >/dev/null 2>&1 &
printf '%s\n' "$!" >>"$DATA/orchestrators"
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
id=$(sed -n 's/^night \([0-9]\{8\}T[0-9]\{6\}Z-[0-9a-f]\{4\}\) started: orchestrator on acct-n$/\1/p' "$WORK/out")
assert [ -n "$id" ]
R=$(record "$id")
assert jqe 'keys == (["id", "started_at", "finished_at", "session", "account", "command", "note",
  "doctors_before", "doctors_after", "jobs"] | sort)' "$R"
assert jqe '.doctors_before == {llm: 5, harness: 3, updater: null} and .doctors_after == null and .jobs == []
  and .finished_at == null and .account == "acct-n"' "$R"
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
assert grep -qxF -- '--account claudeb --role chat --model opus --claim' "$DATA/pick-args"

# A night whose orchestrator chat runs refuses a second start, however long it runs; no deadline flag.
assert_fails night start 2>"$WORK/err"
assert grep -qF "night $id is still running" "$WORK/err"
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
side_hash=$(git -C "$WORK/repo" -c user.name=t -c user.email=t@t commit-tree "HEAD^{tree}" -p HEAD -m side)
git -C "$WORK/repo" push -q origin "$side_hash:refs/heads/side"
git -C "$WORK/repo" -c user.name=t -c user.email=t@t commit -q --allow-empty -m two
local_hash=$(git -C "$WORK/repo" rev-parse HEAD)
printf '%s\n' "$WORK/elsewhere/llm-legs" "$WORK/repo" >"$WORK/sweep-repos"
assert_fails night job "$id" set llm-20260930T010203Z pushed=true 2>"$WORK/err"
assert grep -qF 'needs the job' "$WORK/err"
night job "$id" set llm-20260930T010203Z state=merged "commits=repo:$local_hash" review=rb-1 >/dev/null || fail "set merged"
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
night job "$id" set p1 state=blocked-on-egor reason="step 10 needs his word" >/dev/null || fail "set blocked"

# Menu and report while running.
# Plain words for the Doctors menu: a title line, then one line per job; red only where Egor is needed.
night latest --menu >"$WORK/menu"
started=$(jq -r '.started_at | fromdateiso8601 | strflocaltime("%H:%M")' "$R")
assert [ "$(head -1 "$WORK/menu")" = "$(printf 'Night run since %s: 2 of 12 done and pushed · 1 unfinished · 7 in progress · 1 failed to launch · 1 need you\t1\t1\t%s' "$started" "$id")" ]
assert grep -qxF "$(printf 'LLM fixer · done and pushed\t0\t\tllm-20260930T010203Z\tfixer\t0')" "$WORK/menu"
assert grep -qxF "$(printf 'cleanup debt-round · unfinished · hung\t0\thung: idle 1800\tdebt-round\tdebt\t0')" "$WORK/menu"
assert grep -qxF "$(printf 'harness-r1 · failed to launch · opener\t1\topener\tharness-r1\tfixer\t0')" "$WORK/menu"
assert grep -qxF "$(printf 'cleanup p1 · needs you · step 10 needs his word\t1\tstep 10 needs his word\tp1\tdebt\t0')" "$WORK/menu"
assert grep -qxF "$(printf 'cleanup p2 · in progress\t0\t\tp2\tdebt\t0')" "$WORK/menu"
assert [ "$(wc -l <"$WORK/menu" | tr -d ' ')" = 13 ]

# finish: doctors after, pending becomes left with a reason; a second finish refuses.
doc llm 1
doc harness 0
doc updater 2
night finish "$id" >/dev/null || fail "finish"
assert_fails night finish "$id" 2>/dev/null
assert jqe '.doctors_after == {llm: 1, harness: 0, updater: 2} and .finished_at != null
  and ([.jobs[] | select(.state == "pending")] | length) == 0
  and ([.jobs[] | select(.ref == "p2")][0] | .state == "left" and .reason == "no outcome recorded by the close")' "$R"
mkdir -p "$DOCTORS_DIR/runs"
printf '{"decisions": [{"id": "load:busy", "component": "unverified"}, {"id": "R1"}, {"id": "reading-miss:x", "component": "unverified"}]}\n' \
  >"$DOCTORS_DIR/runs/llm-20260930T010203Z.json"
printf '{"decisions": [{"id": "R2"}]}\n' >"$DOCTORS_DIR/runs/harness-r1.json"
night report "$id" >"$WORK/report" || fail "report"
assert grep -qxF "unverified component · llm-20260930T010203Z · load:busy, reading-miss:x" "$WORK/report"
assert [ "$(grep -c '^unverified' "$WORK/report")" = 1 ]
assert grep -qxF "doctors · llm 5→1 · harness 3→0 · updater -→2" "$WORK/report"
assert grep -qxF "merged · fixer · llm-20260930T010203Z · review rb-1 · repo@${pushed_hash:0:7} · code +0/-0 · pushed" "$WORK/report"
assert grep -qxF "left · debt · debt-round · hung: idle 1800" "$WORK/report"
assert grep -qxF "failed-launch · fixer · harness-r1 · night/$id/harness-r1 · opener" "$WORK/report"
assert grep -qxF "total · 2 merged · 8 left · 1 failed-launch · 1 blocked-on-egor · pushed" "$WORK/report"
assert [ "$(wc -l <"$WORK/report" | tr -d ' ')" = 16 ]
assert [ "$(awk '{ print length }' "$WORK/report" | sort -n | tail -1)" -le 100 ]
assert cmp -s "$WORK/report" <(night report)
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
assert [ "$(night latest --menu | head -1)" = "$(printf 'Last night %s: 2 of 2 done and pushed\t0\t0\t%s' "$day2" "$id2")" ]
night report | head -1 | grep -q "^night $id2 " || fail "report without an id reads the latest night"
night job "$id2" set v1 state=merged "commits=repo:$local_hash" >/dev/null
assert [ "$(night latest --menu | head -1)" = "$(printf 'Last night %s: 2 of 2 done · 1 not pushed yet\t0\t0\t%s' "$day2" "$id2")" ]
assert grep -qxF "$(printf 'v1 update · done, not pushed yet\t0\t\tv1\tvendor\t0')" <(night latest --menu)
night job "$id2" set f1 state=nothing-to-do >/dev/null
night job "$id2" set v1 state=nothing-to-do >/dev/null
assert [ "$(night latest --menu | head -1)" = "$(printf 'Last night %s: 2 of 2 done\t0\t0\t%s' "$day2" "$id2")" ]

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
assert [ "$(night report "$id3" | head -1)" = "night $id3 · $(jq -r '.started_at | fromdateiso8601 | strflocaltime("%H:%M")' "$(record "$id3")")–- · UNFINISHED" ]
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
assert grep -qxF "$(printf 'codex update · unfinished · hung\t0\thung: idle 1800, branch night/x/codex\tcodex-e1\tvendor\t1')" <(night latest --menu)
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
assert grep -q "^codex update · in progress · hung	0	.*	codex-e1	vendor	0$" <(night latest --menu)
stop_chat "$new_session"
night start --resume "$id6" >/dev/null || fail "resume every unfinished job"
assert jqe --arg o "$old_session" --arg n "$new_session" '.previous_sessions == [$o, $n]
  and ([.jobs[] | [.ref, .kind, .state]] == [["codex-e1", "vendor", "pending"], ["f-done", "fixer", "nothing-to-do"],
    ["debt", "debt", "pending"]])' "$R6"
stop_chat "$(jq -r .session "$R6")"
night finish "$id6" >/dev/null
night job "$id6" set debt state=nothing-to-do >/dev/null
night start --resume "$id6" >/dev/null || fail "resume adds the cleanup a done one no longer covers"
assert jqe '[.jobs[] | select(.kind == "debt") | [.ref, .state]] == [["debt", "nothing-to-do"], ["debt-2", "pending"]]' "$R6"
assert grep -q "^cleanup · in progress	0		debt-2	debt	0$" <(night latest --menu)
stop_chat "$(jq -r .session "$R6")"
touch "$DATA/opener-fails"
assert_fails night start --resume "$id6" 2>/dev/null
assert jqe '.finished_at != null and (.note | startswith("orchestrator chat did not open")) and (.previous_sessions | length) == 4' "$R6"
rm "$DATA/opener-fails"

# Cleanup alone: a new night whose orchestrator prompt carries the sweep word and the cleanup scope.
night start --cleanup >"$WORK/out" || fail "cleanup start"
idc=$(sed -n 's/^night \([^ ]*\) started:.*/\1/p' "$WORK/out")
assert [ -n "$idc" ] && [ "$idc" != "$id6" ]
assert [ "$(last_arg "$idc")" = "сделай чистку — night run $idc cleanup" ]
assert jqe '.jobs == [] and .finished_at == null' "$(record "$idc")"
assert_fails night start --cleanup 2>/dev/null
stop_chat "$(jq -r .session "$(record "$idc")")"

# finish prunes every landed (in main, or a night branch still at its base), clean, not live branch of
# the sweep repositories, night or not, with its worktree. Live = the main checkout, a process inside, a
# running night's branch, or a non-night branch whose reflog or dirty files moved within 6 h; every other
# branch is a leftover to carry into main, never kept.
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
old worktree add -q -b stale-dirty "$wt/stale-dirty" "$pushed_hash"
printf 'wip\n' >"$wt/stale-dirty/wip"
touch -t 202601010000 "$wt/stale-dirty/wip"
old worktree add -q -b edited "$wt/edited" "$pushed_hash"
printf 'wip\n' >"$wt/edited/wip"
old worktree add -q -b plain-busy "$wt/plain-busy" "$pushed_hash"
(cd "$wt/busy" && exec sleep 600) &
busy=$!
(cd "$wt/plain-busy/" && exec sleep 600) &
plain_busy=$!
printf '%s\n' "$busy" "$plain_busy" >>"$DATA/orchestrators"
behind=$(git -C "$WORK/repo" rev-list --count "$pushed_hash..main")
night leftovers >"$WORK/left" || fail "leftovers"
night leftovers --json >"$WORK/left.json" || fail "leftovers --json"
assert grep -qxF "repo merged-bare · no worktree · landed · +0/-$behind main · 0 dirty · landed" "$WORK/left"
assert grep -qxF "repo stale-open · $wt/stale-open · unlanded · +1/-3 main · 0 dirty · leftover (1 unlanded commits)" "$WORK/left"
assert grep -qxF "repo stale-bare · no worktree · unlanded · +1/-3 main · 0 dirty · leftover (1 unlanded commits)" "$WORK/left"
assert grep -qxF "repo stale-dirty · $wt/stale-dirty · landed · +0/-$behind main · 1 dirty · leftover (1 uncommitted files)" "$WORK/left"
assert grep -qxF "repo plain-busy · $wt/plain-busy · landed · +0/-$behind main · 0 dirty · live (a process inside)" "$WORK/left"
assert grep -qxE "repo fresh · $wt/fresh · landed · \+0/-$behind main · 0 dirty · live \(active [0-9]+m ago\)" "$WORK/left"
assert grep -qxE "repo edited · .* · 1 dirty · live \(active [0-9]+m ago\)" "$WORK/left"
assert_fails grep -q '^repo main ' "$WORK/left"
assert [ "$(wc -l <"$WORK/left" | tr -d ' ')" = 13 ]
assert jqe --arg w "$wt" 'length == 13 and (map(.branch) | index("main")) == null
  and (.[] | select(.branch == "stale-open")) == {repo: ($w | sub("/.claude/worktrees$"; "")), branch: "stale-open",
    worktree: "\($w)/stale-open", landed: false, ahead: 1, behind: 3, dirty: 0, live: false, state: "leftover",
    why: "1 unlanded commits"}
  and ((.[] | select(.branch == "merged-bare")) | .worktree == null and .landed and .state == "landed" and .why == null)
  and ((.[] | select(.branch == "fresh")) | .live and .state == "live")' "$WORK/left.json"
night finish "$idc" >"$WORK/out" || fail "finish with worktrees"
kill "$busy" "$plain_busy" 2>/dev/null
assert grep -qxF "pruned repo night/$id/landed" "$WORK/out"
assert grep -qxF "pruned repo night/$idc/at-base" "$WORK/out"
assert grep -qxF "pruned repo merged-old" "$WORK/out"
assert grep -qxF "pruned repo merged-bare" "$WORK/out"
assert grep -qxF "leftover repo night/$idc/dirty: 1 uncommitted files" "$WORK/out"
assert grep -qxF "leftover repo night/$idc/open: 1 unlanded commits" "$WORK/out"
assert grep -qxF "leftover repo stale-open: 1 unlanded commits" "$WORK/out"
assert grep -qxF "leftover repo stale-bare: 1 unlanded commits" "$WORK/out"
assert grep -qxF "leftover repo stale-dirty: 1 uncommitted files" "$WORK/out"
assert grep -qxF "live repo night/$idc/busy: a process inside" "$WORK/out"
assert grep -qxF "live repo plain-busy: a process inside" "$WORK/out"
assert grep -qxE "live repo fresh: active [0-9]+m ago" "$WORK/out"
assert grep -qxE "live repo edited: active [0-9]+m ago" "$WORK/out"
assert_fails grep -q '^kept ' "$WORK/out"
assert [ "$(wc -l <"$WORK/out" | tr -d ' ')" = 14 ]
assert [ ! -e "$wt/landed" ] && [ ! -e "$wt/at-base" ] && [ ! -e "$wt/merged-old" ]
assert [ -e "$wt/dirty/wip" ] && [ -d "$wt/open" ] && [ -d "$wt/fresh" ] && [ -d "$wt/stale-open" ] && [ -e "$wt/stale-dirty/wip" ]
for gone in "night/$id/landed" merged-old merged-bare; do
  assert_fails git -C "$WORK/repo" rev-parse -q --verify "refs/heads/$gone"
done
for stays in "night/$idc/open" stale-open stale-bare stale-dirty fresh edited plain-busy; do
  assert git -C "$WORK/repo" rev-parse -q --verify "refs/heads/$stays" >/dev/null
done
assert jqe '([.leftovers[] | .branch] | sort) == (["night/'"$idc"'/dirty", "night/'"$idc"'/open", "stale-bare", "stale-dirty", "stale-open"] | sort)' "$(record "$idc")"
assert grep -qxF "leftover · repo · stale-open · 1 unlanded commits" <(night report "$idc")

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
assert grep -q "^leftover stale-dirty · unfinished	0		leftover-stale-dirty	leftover	1$" <(night latest --menu)
night job "$idc" add leftover stale-bare >"$WORK/out" || fail "adopt a bare leftover"
assert [ "$(git -C "$WORK/repo" rev-parse "night/$idc/leftover-stale-bare")" = "$side_hash" ]
assert [ -d "$wt/night-$idc-leftover-stale-bare" ]
assert_fails git -C "$WORK/repo" rev-parse -q --verify refs/heads/stale-bare
assert jqe '.jobs[-1].adopted[0] | .branch == "stale-bare" and .worktree == null' "$(record "$idc")"
# Refused, nothing touched: a live branch, a landed one, main, an unknown name, a job already there.
old branch landed-x "$pushed_hash"
for refused in "fresh:fresh is live in repo: active" "landed-x:landed-x is no leftover: landed" \
  "main:no branch main in the sweep repositories" "nosuch:no branch nosuch in the sweep repositories"; do
  assert_fails night job "$idc" add leftover "${refused%%:*}" 2>"$WORK/err"
  assert grep -qF "${refused#*:}" "$WORK/err"
done
assert_fails night job "$idc" add leftover stale-open --branch x 2>/dev/null
assert git -C "$WORK/repo" rev-parse -q --verify refs/heads/landed-x >/dev/null
assert [ -d "$wt/fresh" ] && [ -d "$wt/stale-open" ]
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
printf '%s\n' "$WORK/repo" "$WORK/repo2" >"$WORK/sweep-repos"
assert_fails night job "$idc" add leftover split 2>"$WORK/err"
assert grep -qF "split is live in repo2: active" "$WORK/err"
assert git -C "$WORK/repo" rev-parse -q --verify refs/heads/split >/dev/null
night job "$idc" add leftover both >"$WORK/out" || fail "adopt in every repository"
assert [ "$(grep -c '^adopted repo2\{0,1\} both into night/'"$idc"'/leftover-both at ' "$WORK/out")" = 2 ]
for r in repo repo2; do
  assert [ "$(git -C "$WORK/$r" log -1 --format=%s "night/$idc/leftover-both")" = "$r work" ]
  assert_fails git -C "$WORK/$r" rev-parse -q --verify refs/heads/both
done
assert jqe '.jobs[-1] | .ref == "leftover-both" and ([.adopted[] | .repo | split("/") | last] == ["repo", "repo2"])' "$(record "$idc")"
assert_fails night job "$idc" add leftover both 2>/dev/null
printf '%s\n' "$WORK/repo" >"$WORK/sweep-repos"

# A vendor job is named by its branch's vendor, whatever run ref its updater fixer got.
night job "$idc" add vendor updater-release-20261001T020703Z-0d10 --branch "night/$idc/codex" >/dev/null
assert grep -q "^codex update · " <(night latest --menu)

# Fixer runs recorded under an area's old name keep their menu word; the doctor's own area names no word.
for ref in llm-health-20261001T020632Z-3671 harness-self-20261001T020659Z-1dba updater-machinery-20261001T020659Z-1dba \
    llm-doctor-20261001T030000Z-0a0a harness-hook-waits-20261001T020655Z-4a9f; do
  night job "$idc" add fixer "$ref" >/dev/null || fail "job add $ref"
done
assert [ "$(night latest --menu | cut -f1 | grep ' fixer' | sed 's/ · .*//' | paste -sd, -)" \
  = "LLM fixer: debt,Harness fixer,Updater fixer,LLM fixer,Harness fixer: hook waits" ]

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

# No night at all: the menu prints nothing.
rm "$NIGHTS"/*.json
assert [ -z "$(night latest --menu)" ]
assert_fails night report 2>/dev/null

echo "PASS: test_night_run.sh ($asserts asserts)"
