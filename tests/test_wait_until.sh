#!/usr/bin/env bash
. "${BASH_SOURCE%"${BASH_SOURCE##*/}"}lib/suite-journal.sh"
# bin/wait-until ends with the job it waits on (a pid, a pgrep pattern, a glob's file count, a log line) or at its cap.
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
WORK="$(cd -P "$(mktemp -d)" && pwd)"
trap 'kill $(jobs -p) 2>/dev/null; rm -rf "$WORK"' EXIT
asserts=0
like() { [[ $1 == $2 ]]; }
W="$ROOT/bin/wait-until"
export WAIT_UNTIL_POLL_S=0.2

out=$("$W" --max 5 pid 999999) && like "$out" "met: pid 999999 exited after *" || fail "a dead pid: $out"
sleep 30 & live=$!
out=$("$W" --max 1 pid $live); rc=$?
assert [ $rc -eq 1 ]
assert [ "$out" = "timeout after 1s" ]
( sleep 1; kill $live ) &
out=$("$W" --max 20 pid $live) && assert [ "$out" = "met: pid $live exited after 1s" ]

# gone: a process whose argv holds the pattern keeps it waiting; the call's own argv never does.
marker="wu-marker-$$-$RANDOM"
bash -c 'exec -a "$1" sleep 30' _ "$marker" & held=$!
sleep 0.3
"$W" --max 1 gone "$marker" >/dev/null; assert [ $? -eq 1 ]
kill $held
sleep 0.3
out=$("$W" --max 5 gone "$marker") ; assert [ $? -eq 0 ]
assert like "$out" "met: no process matches $marker after "*
# A chat's prompt naming the pattern never holds it: claude and its caffeinate child carry the prompt in argv.
for name in claude caffeinate; do
  bash -c 'exec -a "$1" bash -c "sleep 30; :" "$2"' _ "$name" "$marker" & held=$!
  sleep 0.3
  out=$("$W" --max 2 gone "$marker"); assert [ $? -eq 0 ]
  kill $held
done

# files: the count decides, not the first match.
mkdir "$WORK/out"
touch "$WORK/out/a.png"
"$W" --max 1 files "$WORK/out/*.png" 2 >/dev/null; assert [ $? -eq 1 ]
( sleep 1; touch "$WORK/out/b.png" ) &
out=$("$W" --max 20 files "$WORK/out/*.png" 2); assert [ $? -eq 0 ]
assert like "$out" "met: 2 paths match "*
# A plain path is waited for, not counted while it is absent (night 5921: `files <flag> 1` met at 0 s).
"$W" --max 1 files "$WORK/out/finished" 1 >/dev/null; assert [ $? -eq 1 ]
touch "$WORK/out/finished"
"$W" --max 1 files "$WORK/out/finished" 1 >/dev/null; assert [ $? -eq 0 ]

# log: absent file waits, a late line ends it, an existing one counts.
"$W" --max 1 log "$WORK/run.log" 'DONE' >/dev/null; assert [ $? -eq 1 ]
echo 'step 1' >"$WORK/run.log"
"$W" --max 1 log "$WORK/run.log" 'DONE|FAIL' >/dev/null; assert [ $? -eq 1 ]
( sleep 1; echo 'FAIL x' >>"$WORK/run.log" ) &
out=$("$W" --max 20 log "$WORK/run.log" 'DONE|FAIL'); assert [ $? -eq 0 ]
assert like "$out" "met: $WORK/run.log matches DONE|FAIL after "*

# the default cap is the Bash call's default timeout less 30 s; usage errors exit 2.
out=$(BASH_DEFAULT_TIMEOUT_MS=31000 "$W" log "$WORK/none" x); assert [ $? -eq 1 ]
assert [ "$out" = "timeout after 1s" ]
for bad in "" "pid" "pid x" "files $WORK/* y" "nope 1" "--max x pid 1"; do
  # shellcheck disable=SC2086
  "$W" $bad >/dev/null 2>&1; assert [ $? -eq 2 ]
done

printf 'PASS: test_wait_until.sh (%s asserts)\n' "$asserts"
