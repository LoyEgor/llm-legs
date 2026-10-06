#!/usr/bin/env bash
. "${BASH_SOURCE%"${BASH_SOURCE##*/}"}lib/suite-journal.sh"
# run-suites' per-suite wall bound: a hung suite is killed with its whole process tree and the run goes
# on; the bound comes from the suite's own passes in the journal, doubled for tests/slow-suites.
set -u
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)
WORK=$(cd "$(mktemp -d)" && pwd -P)
trap '[ ! -s "$WORK/grandchild" ] || kill "$(cat "$WORK/grandchild")" 2>/dev/null; rm -rf "$WORK"' EXIT
asserts=0
fail() { printf 'FAIL: %s\n' "$*" >&2; [ ! -r "$WORK/out" ] || cat "$WORK/out" >&2; exit 1; }
assert() { asserts=$((asserts + 1)); "$@" || fail "assert $asserts: $*"; }
assert_fails() { asserts=$((asserts + 1)); ! "$@" || fail "assert $asserts unexpectedly held: $*"; }
export HOME="$WORK/home" XDG_CACHE_HOME="$WORK/xdg" HARNESS_HOLDS_DIR="$WORK/holds" STATUSLINE_CACHE_DIR="$WORK/sl" \
  RUN_SUITES_TIMES="$WORK/rs/times.tsv" RUN_SUITES_SLOTS_DIR="$WORK/slots" RUN_SUITES_JOURNAL="$WORK/rs/runs.jsonl" \
  RUN_SUITES_SUITE_FLOOR=1
unset RUN_SUITES_SLOT SUITE_JOURNAL SUITE_JOURNAL_PID WORKER_RUN_ID CLAUDE_LAUNCHER_SESSION
REPO="$WORK/repo"
mkdir -p "$HOME" "$WORK/rs" "$REPO/tests"

printf '#!/usr/bin/env bash\nsleep 60 &\necho "$!" >"%s/grandchild"\nwait\n' "$WORK" >"$REPO/tests/test_hang.sh"
printf '#!/usr/bin/env bash\nsleep 3\necho ok\n' >"$REPO/tests/test_known.sh"
printf '#!/usr/bin/env bash\nsleep 3\necho ok\n' >"$REPO/tests/test_slow.sh"
printf '#!/usr/bin/env bash\necho ok\n' >"$REPO/tests/test_quick.sh"
printf 'test_slow.sh\n' >"$REPO/tests/slow-suites"
# test_known.sh passed in 1 s three times (bound 5 x 1 s); test_hang.sh and test_slow.sh have no history
# (bounds 2 x floor = 2 s, and 2 x the doubled floor = 4 s); a failed run and another repo do not count.
for secs in 1 0.4 1; do
  jq -nc --arg r "$REPO" --argjson s "$secs" '{kind: "suites", repo_root: $r, suites: {"test_known.sh": {rc: 0, secs: $s}}}'
done >"$RUN_SUITES_JOURNAL"
jq -nc --arg r "$REPO" '{kind: "suites", repo_root: $r, suites: {"test_hang.sh": {rc: 1, secs: 100}}}' >>"$RUN_SUITES_JOURNAL"
jq -nc '{kind: "suites", repo_root: "/elsewhere", suites: {"test_hang.sh": {rc: 0, secs: 100}}}' >>"$RUN_SUITES_JOURNAL"
jq -nc '{kind: "suites", repo_root: "/elsewhere", suites: {"test_hang.sh": {rc: 0, secs: 100}}}' >>"$RUN_SUITES_JOURNAL"
jq -nc '{kind: "suites", repo_root: "/elsewhere", suites: {"test_hang.sh": {rc: 0, secs: 100}}}' >>"$RUN_SUITES_JOURNAL"
printf 'not json\n' >>"$RUN_SUITES_JOURNAL"

began=$SECONDS
rc=0
bash "$ROOT/share/run-suites.sh" --repo "$REPO" -j 4 >"$WORK/out" 2>&1 || rc=$?
took=$((SECONDS - began))
assert test "$rc" = 1
assert test "$took" -lt 30
assert grep -qE '^test_hang\.sh +FAIL 124 +[0-9]+ +run-suites: TIMEOUT after 2 s, its process tree killed$' "$WORK/out"
assert grep -qE '^test_known\.sh +PASS ' "$WORK/out"
assert grep -qE '^test_slow\.sh +PASS ' "$WORK/out"
assert grep -qE '^test_quick\.sh +PASS ' "$WORK/out"
assert grep -qF '4 suites · 3 PASS · 1 FAIL' "$WORK/out"
assert test -s "$WORK/grandchild"
assert_fails kill -0 "$(cat "$WORK/grandchild")" 2>/dev/null
assert jq -enR --arg r "$REPO" '[inputs | fromjson? | select(.repo_root == $r and .pid != null)]
  | length == 1 and .[0].suites["test_hang.sh"].rc == 124 and .[0].suites["test_known.sh"].rc == 0' "$RUN_SUITES_JOURNAL" >/dev/null
assert jq -enR --arg r "$REPO" '[inputs | fromjson? | select(.repo_root == $r and .pid != null)][0].suites | map_values(.bound)
  == {"test_hang.sh": 2, "test_known.sh": 5, "test_slow.sh": 4, "test_quick.sh": 2}' "$RUN_SUITES_JOURNAL" >/dev/null

# The floor must be whole seconds.
rc=0
RUN_SUITES_SUITE_FLOOR=0 bash "$ROOT/share/run-suites.sh" --repo "$REPO" test_quick.sh >"$WORK/out" 2>&1 || rc=$?
assert test "$rc" = 4
assert grep -qF 'RUN_SUITES_SUITE_FLOOR must be whole seconds' "$WORK/out"

printf 'PASS: %s asserts\n' "$asserts"
