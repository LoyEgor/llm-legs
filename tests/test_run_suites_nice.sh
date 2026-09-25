#!/usr/bin/env bash
set -u
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)
WORK=$(cd "$(mktemp -d)" && pwd -P)
trap 'rm -rf "$WORK"' EXIT
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

printf 'PASS: %s asserts; run-suites runs every suite at nice 10, in parallel, and a worktree finds its siblings\n' "$asserts"
