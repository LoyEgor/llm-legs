#!/usr/bin/env bash
set -u
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)
WORK=$(cd "$(mktemp -d)" && pwd -P)
trap 'rm -rf "$WORK"' EXIT
export STATUSLINE_CACHE_DIR="$WORK/sl"
export RUN_SUITES_TIMES="$WORK/times.tsv"
asserts=0
assert() { asserts=$((asserts + 1)); "$@" || { printf 'FAIL: assert %s: %s\n' "$asserts" "$*"; exit 1; }; }

mkdir -p "$WORK/repo/tests"
for name in a b; do
  printf '#!/usr/bin/env bash\necho "PASS: nice=$(ps -o nice= -p $$ | tr -d " ")"\n' >"$WORK/repo/tests/test_$name.sh"
done

# Every suite runs below interactive priority, in parallel as before.
out=$(bash "$ROOT/share/run-suites.sh" --repo "$WORK/repo" 2>&1)
assert test "$(grep -c 'PASS: nice=10' <<<"$out")" = 2
assert grep -q '2 PASS' <<<"$out"

# A suite in a linked worktree finds its sibling repositories beside the main checkout.
mkdir -p "$WORK/projects/main" "$WORK/projects/claude-setup" "$WORK/projects/review-bench"
git -C "$WORK/projects/main" init -q
git -C "$WORK/projects/main" -c user.name=t -c user.email=t@t -c core.hooksPath=/dev/null commit -q --allow-empty -m init
git -C "$WORK/projects/main" worktree add -q --detach "$WORK/projects/main/.claude/worktrees/b"
tree="$WORK/projects/main/.claude/worktrees/b"
mkdir -p "$tree/tests"
printf '#!/usr/bin/env bash\n[ "$CLAUDE_SETUP_ROOT|$REVIEW_BENCH_ROOT" = "$WANT" ] && echo "PASS: siblings" || echo "FAIL: $CLAUDE_SETUP_ROOT"\n' >"$tree/tests/test_s.sh"
out=$(env -u CLAUDE_SETUP_ROOT -u REVIEW_BENCH_ROOT WANT="$WORK/projects/claude-setup|$WORK/projects/review-bench" \
  bash "$ROOT/share/run-suites.sh" --repo "$tree" 2>&1)
assert grep -q 'PASS: siblings' <<<"$out"
out=$(CLAUDE_SETUP_ROOT=/elsewhere REVIEW_BENCH_ROOT=/other WANT='/elsewhere|/other' bash "$ROOT/share/run-suites.sh" --repo "$tree" 2>&1)
assert grep -q 'PASS: siblings' <<<"$out"

# While it runs, the statusline's work probe finds its log directory, suite count and repository
# by its pid; the repository is the one it was handed, never the caller's directory.
mkdir -p "$WORK/count/tests"
printf '#!/usr/bin/env bash\ncat "$STATUSLINE_CACHE_DIR"/suites-* >"$SEEN"; echo PASS\n' >"$WORK/count/tests/test_c.sh"
(cd "$WORK" && SEEN="$WORK/seen" bash "$ROOT/share/run-suites.sh" --repo "$WORK/count" >/dev/null 2>&1)
assert grep -Eq $'^/.*/run-suites\\.[A-Za-z0-9]+\t1\t/.*/count$' "$WORK/seen"
assert test -z "$(ls "$WORK/sl")"

# The wave starts the longest suite first by its last passing duration, an unknown one before all;
# another repository's durations are neither read nor dropped.
mkdir -p "$WORK/order/tests"
for name in a b c d; do
  printf '#!/usr/bin/env bash\necho %s >>"$ORDER"; echo PASS\n' "$name" >"$WORK/order/tests/test_$name.sh"
done
printf '%s\t%s\t%s\n' "$WORK/order" test_a.sh 5 "$WORK/order" test_b.sh 50 "$WORK/order" test_c.sh 20 \
  /elsewhere test_d.sh 99 >"$RUN_SUITES_TIMES"
ORDER="$WORK/order.log" bash "$ROOT/share/run-suites.sh" --repo "$WORK/order" -j 1 >/dev/null 2>&1
assert test "$(tr '\n' ' ' <"$WORK/order.log")" = "d b c a "
assert grep -q $'^/elsewhere\ttest_d.sh\t99$' "$RUN_SUITES_TIMES"
assert grep -Eq "^$WORK/order"$'\ttest_d.sh\t[01]$' "$RUN_SUITES_TIMES"
assert test "$(grep -c "^$WORK/order"$'\t' "$RUN_SUITES_TIMES")" = 4

printf 'PASS: %s asserts; run-suites runs every suite at nice 10, in parallel, longest first, a worktree finds its siblings, and a run leaves its progress pointer only while it lasts\n' "$asserts"
