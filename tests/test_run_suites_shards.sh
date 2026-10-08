#!/usr/bin/env bash
. "${BASH_SOURCE%"${BASH_SOURCE##*/}"}lib/suite-journal.sh"
# A `# shards: N` suite: N jobs under one -j, one verdict and one journal entry, every section run
# exactly once across its shards, and suite_shard_owns refusing any section no shard could own.
set -u
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)
WORK=$(cd "$(mktemp -d)" && pwd -P)
trap 'rm -rf "$WORK"' EXIT
asserts=0
fail() { printf 'FAIL: %s\n' "$*" >&2; [ ! -r "$WORK/out" ] || cat "$WORK/out" >&2; exit 1; }
assert() { asserts=$((asserts + 1)); "$@" || fail "assert $asserts: $*"; }
assert_fails() { asserts=$((asserts + 1)); ! "$@" || fail "assert $asserts unexpectedly held: $*"; }
jqe() { jq -e "$@" >/dev/null; }
export HOME="$WORK/home" XDG_CACHE_HOME="$WORK/xdg" HARNESS_HOLDS_DIR="$WORK/holds" STATUSLINE_CACHE_DIR="$WORK/sl" \
  RUN_SUITES_TIMES="$WORK/rs/times.tsv" RUN_SUITES_SLOTS_DIR="$WORK/slots" RUN_SUITES_JOURNAL="$WORK/rs/runs.jsonl"
unset RUN_SUITES_SLOT SUITE_JOURNAL SUITE_JOURNAL_PID WORKER_RUN_ID CLAUDE_LAUNCHER_SESSION SUITE_SHARD RUN_SUITES_SHARDS
LIB="$ROOT/tests/lib/suite-journal.sh"
REPO="$WORK/repo"
mkdir -p "$HOME" "$WORK/rs" "$REPO/tests"
git -C "$REPO" init -q
git -C "$REPO" -c user.name=t -c user.email=t@t -c core.hooksPath=/dev/null commit -q --allow-empty -m init

# Each section logs its name and how many shard bodies run beside it; shard 3 outlasts shard 1 by 2 s.
cat >"$REPO/tests/test_sharded.sh" <<EOF
#!/usr/bin/env bash
# shards: 3
. "$LIB"
ran=0
section() { printf '%s\\n' "\$1" >>"$WORK/sections"; ran=\$((ran + 1)); }
echo setup
mkdir "$WORK/live.\$\$"; trap 'rmdir "$WORK/live.\$\$"' EXIT
ls -d "$WORK"/live.* | wc -l | tr -d ' ' >>"$WORK/concurrent"
if suite_shard_owns 1 a; then section a; sleep 1; fi
if suite_shard_owns 2 b; then section b; i=0; while [ "\$i" -lt 200000 ]; do i=\$((i + 1)); done; fi
if suite_shard_owns 3 c; then section c; sleep 3; [ -z "\${FAIL_C:-}" ] || { echo "c failed"; exit 5; }; fi
if suite_shard_owns 1 d; then section d; fi
bash "$WORK/child.sh"
echo "PASS: \$ran sections run"
EOF
printf '#!/usr/bin/env bash\nprintf "%%s\\n" "${SUITE_SHARD:-}" >>"%s/child"\n' "$WORK" >"$WORK/child.sh"
run() { # env... -- runner-arg... -> run-suites over $REPO, its output in $WORK/out
  local -a vars=()
  while [ "$1" != -- ]; do vars+=("$1"); shift; done
  shift
  : >"$WORK/sections"; : >"$WORK/concurrent"; : >"$WORK/child"
  env ${vars[@]+"${vars[@]}"} bash "$ROOT/share/run-suites.sh" --repo "$REPO" "$@" >"$WORK/out" 2>&1
}
sections() { sort "$WORK/sections" | tr '\n' ' '; }
row() { tail -1 "$RUN_SUITES_JOURNAL"; }

# Three jobs, one row: the suite's wall is its slowest shard's, its CPU every shard's, each section once.
run RUN_SUITES_SHARDS=on -- -j 3
assert test "$?" = 0
assert grep -q '1 suites, 3 jobs, -j 3' "$WORK/out"
assert test "$(sections)" = 'a b c d '
assert test "$(sort -n "$WORK/concurrent" | tail -1)" = 3
assert test "$(wc -l <"$RUN_SUITES_JOURNAL" | tr -d ' ')" = 1
assert jqe '(.suites | keys) == ["test_sharded.sh"] and .suites["test_sharded.sh"].rc == 0
  and .suites["test_sharded.sh"].shards == 3 and .suites["test_sharded.sh"].secs >= 3 and .suites["test_sharded.sh"].secs < 4' <(row)
logdir=$(sed -n 's/.*logs under //p' "$WORK/out")
cpu_ms=0
for st in "$logdir"/test_sharded.sh.shard-*.st; do
  IFS=$'\t' read -r _ _ _ _ cpu <"$st"
  cpu_ms=$((cpu_ms + ${cpu%.*} * 1000 + 10#${cpu#*.}))
done
suite_journal_secs cpu_sum "$cpu_ms"
assert jqe --argjson cpu "$cpu_sum" '.suites["test_sharded.sh"].cpu_s == $cpu' <(row)
# The table's last line counts every shard's sections, not the last shard's.
assert grep -qx 'test_sharded.sh  PASS .*  PASS: 4 sections run' "$WORK/out"
# A suite the shard runs is whole: SUITE_SHARD stops at the suite that owns it.
assert test "$(sort -u "$WORK/child")" = ''

# The shards share the run's -j: at -j 2 never three at once.
run RUN_SUITES_SHARDS=on -- -j 2
assert test "$(sections)" = 'a b c d '
assert test "$(sort -n "$WORK/concurrent" | tail -1)" -le 2

# A failing shard fails the suite, and the failure tail is that shard's.
run RUN_SUITES_SHARDS=on FAIL_C=1 -- -j 3
assert test "$?" = 1
assert jqe '.suites["test_sharded.sh"].rc == 5 and .complete == true' <(row)
assert grep -q '^test_sharded.sh  FAIL 5 .*c failed' "$WORK/out"
assert grep -q '== run-suites: shard 3/3, exit 5' <(sed -n '/=== test_sharded.sh (last 30 lines)/,$p' "$WORK/out")

# Off, and with no room on the machine, it is one job of every section, exactly as a direct run.
run RUN_SUITES_SHARDS=off -- -j 3
assert grep -q '1 suites, 1 jobs' "$WORK/out"
assert test "$(sections)" = 'a b c d '
assert jqe '.suites["test_sharded.sh"] | .rc == 0 and (has("shards") | not)' <(row)
run SLOTS_ROOM_MB=999999999 -- -j 3
assert grep -q '1 suites, 1 jobs' "$WORK/out"
: >"$WORK/sections"
bash "$REPO/tests/test_sharded.sh" >/dev/null 2>&1
assert test "$(sections)" = 'a b c d '
: >"$WORK/sections"
SUITE_SHARD=2/3 bash "$REPO/tests/test_sharded.sh" >/dev/null 2>&1
assert test "$(sections)" = 'b '

# No section can sit outside every shard: an index past the header, a missing or repeated name, and a
# SUITE_SHARD the header does not declare each end the suite.
for body in 'suite_shard_owns 4 x' 'suite_shard_owns 0 x' 'suite_shard_owns 1' 'suite_shard_owns 1 x; suite_shard_owns 2 x'; do
  printf '#!/usr/bin/env bash\n# shards: 3\n. "%s"\n%s\nexit 0\n' "$LIB" "$body" >"$WORK/bad.sh"
  bash "$WORK/bad.sh" >/dev/null 2>&1
  assert test "$?" = 2
done
for shard in 4/3 1/2 x; do
  SUITE_SHARD=$shard bash "$REPO/tests/test_sharded.sh" >/dev/null 2>&1
  assert test "$?" = 2
done

# Every sharded suite of this repository and claude-setup: literal indexes within its header, unique
# names, and no shard left owning nothing.
shard_layout() { # suite -> fails with the reason unless every shard 1..N owns a section
  local n
  n=$(suite_shard_count "$1")
  awk -v n="$n" -v f="$1" '
    /^[[:space:]]*if !? *suite_shard_owns/ {
      if (!match($0, /suite_shard_owns [1-9][0-9]* [^ ;]+;/)) { print f ": a section with no literal shard and name: " $0; bad = 1; next }
      split(substr($0, RSTART, RLENGTH - 1), w, " ")
      if (w[2] + 0 > n) { print f ": shard " w[2] " past " n; bad = 1 }
      if (seen[w[3]]++) { print f ": section " w[3] " twice"; bad = 1 }
      owns[w[2] + 0]++
    }
    END { for (i = 1; i <= n; i++) if (!owns[i]) { print f ": shard " i " owns nothing"; bad = 1 }; exit bad }' "$1"
}
sharded=0
for suite in "$ROOT"/tests/test_*.sh ${CLAUDE_SETUP_ROOT:+"$CLAUDE_SETUP_ROOT"/tests/test_*.sh}; do
  [ "$(suite_shard_count "$suite")" -gt 1 ] || continue
  sharded=$((sharded + 1))
  assert shard_layout "$suite"
done
assert test "$sharded" -ge 3
printf '#!/usr/bin/env bash\n# shards: 2\nif suite_shard_owns 1 a; then :; fi\n' >"$WORK/empty-shard.sh"
assert test "$(shard_layout "$WORK/empty-shard.sh")" = "$WORK/empty-shard.sh: shard 2 owns nothing"

printf 'PASS: %s asserts; sharded suites expand into -j jobs with one verdict and one journal entry, every section run once\n' "$asserts"
