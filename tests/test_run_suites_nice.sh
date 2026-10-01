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
assert test "$(grep -c wall-clock <<<"$out")" = 0

# A suite never sees the launching chat's session id (its worker pin) and writes no bytecode.
mkdir -p "$WORK/env/tests"
printf '#!/usr/bin/env bash\necho "PASS: sid=${CLAUDE_CODE_SESSION_ID:-none} pyc=${PYTHONDONTWRITEBYTECODE:-}"\n' >"$WORK/env/tests/test_env.sh"
out=$(CLAUDE_CODE_SESSION_ID=chat-1 bash "$ROOT/share/run-suites.sh" --repo "$WORK/env" 2>&1)
assert grep -q 'PASS: sid=none pyc=1' <<<"$out"

# Wall-clock budget suites stay at the caller's nice; the parallel wave is what drops to 10.
parent_nice=$(ps -o nice= -p $$ | tr -d '[:space:]')
mkdir -p "$WORK/prio/tests"
printf '#!/usr/bin/env bash\necho "PASS: wave=$(ps -o nice= -p $$ | tr -d " ")"\n' >"$WORK/prio/tests/test_wave.sh"
printf '#!/usr/bin/env bash\necho "PASS: budget=$(ps -o nice= -p $$ | tr -d " ")"\n' >"$WORK/prio/tests/test_commit_journal.sh"
out=$(bash "$ROOT/share/run-suites.sh" --repo "$WORK/prio" 2>&1)
assert grep -q 'PASS: wave=10' <<<"$out"
assert grep -q "PASS: budget=$parent_nice" <<<"$out"
assert grep -q "wall-clock suite(s) stay at nice $parent_nice; the wave is nice 10" <<<"$out"

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

# Same branch in a sibling repo: that worktree. No such worktree: the main checkout. An export wins.
git -C "$WORK/projects/claude-setup" init -q
git -C "$WORK/projects/claude-setup" -c user.name=t -c user.email=t@t -c core.hooksPath=/dev/null commit -q --allow-empty -m init
git -C "$WORK/projects/claude-setup" worktree add -q -b 'night/n/job' "$WORK/projects/claude-setup/.claude/worktrees/night-n-job"
mkdir -p "$WORK/projects/llm-legs"
git -C "$WORK/projects/llm-legs" init -q
git -C "$WORK/projects/llm-legs" -c user.name=t -c user.email=t@t -c core.hooksPath=/dev/null commit -q --allow-empty -m init
git -C "$WORK/projects/llm-legs" worktree add -q -b 'night/n/job' "$WORK/projects/llm-legs/.claude/worktrees/night-n-job"
git -C "$WORK/projects/main" worktree add -q -b 'night/n/job' "$WORK/projects/main/.claude/worktrees/night-n-job"
tree2="$WORK/projects/main/.claude/worktrees/night-n-job"
mkdir -p "$tree2/tests"
setup_wt="$WORK/projects/claude-setup/.claude/worktrees/night-n-job"
legs_wt="$WORK/projects/llm-legs/.claude/worktrees/night-n-job"
bench="$WORK/projects/review-bench"
printf '#!/usr/bin/env bash\n[ "$CLAUDE_SETUP_ROOT|$REVIEW_BENCH_ROOT|$REVIEW_ROOT|$LLM_LEGS_ROOT|$LLM_LEGS_SHARE" = "$WANT" ] && echo PASS: same-branch || echo "FAIL: $CLAUDE_SETUP_ROOT|$REVIEW_BENCH_ROOT|$REVIEW_ROOT|$LLM_LEGS_ROOT|$LLM_LEGS_SHARE"\n' >"$tree2/tests/test_b.sh"
want="$setup_wt|$bench|$bench|$legs_wt|$legs_wt/share"
out=$(env -u CLAUDE_SETUP_ROOT -u REVIEW_BENCH_ROOT -u REVIEW_ROOT -u LLM_LEGS_ROOT -u LLM_LEGS_SHARE WANT="$want" \
  bash "$ROOT/share/run-suites.sh" --repo "$tree2" 2>&1)
assert grep -q 'PASS: same-branch' <<<"$out"
out=$(env -u REVIEW_BENCH_ROOT -u REVIEW_ROOT -u LLM_LEGS_ROOT CLAUDE_SETUP_ROOT=/keep LLM_LEGS_SHARE=/share-kept \
  WANT="/keep|$bench|$bench|$legs_wt|/share-kept" bash "$ROOT/share/run-suites.sh" --repo "$tree2" 2>&1)
assert grep -q 'PASS: same-branch' <<<"$out"
mkdir -p "$WORK/projects/main/tests"
printf '#!/usr/bin/env bash\n[ -z "${CLAUDE_SETUP_ROOT:-}" ] && [ -z "${REVIEW_BENCH_ROOT:-}" ] && echo PASS: beside || echo "FAIL:${CLAUDE_SETUP_ROOT-}:${REVIEW_BENCH_ROOT-}"\n' >"$WORK/projects/main/tests/test_beside.sh"
out=$(env -u CLAUDE_SETUP_ROOT -u REVIEW_BENCH_ROOT -u REVIEW_ROOT -u LLM_LEGS_ROOT \
  bash "$ROOT/share/run-suites.sh" --repo "$WORK/projects/main" 2>&1)
assert grep -q 'PASS: beside' <<<"$out"

# While it runs, the statusline's work probe finds its log directory, suite count and repository
# by its pid; the repository is the one it was handed, never the caller's directory.
mkdir -p "$WORK/count/tests"
printf '#!/usr/bin/env bash\ncat "$STATUSLINE_CACHE_DIR"/suites-* >"$SEEN"; echo PASS\n' >"$WORK/count/tests/test_c.sh"
(cd "$WORK" && SEEN="$WORK/seen" bash "$ROOT/share/run-suites.sh" --repo "$WORK/count" >/dev/null 2>&1)
assert grep -Eq $'^/.*/run-suites\\.[A-Za-z0-9]+\t1\t/.*/count\t[0-9]+$' "$WORK/seen"
assert test -z "$(ls "$WORK/sl" | grep -v '^test-scope\.jsonl$')"
assert test "$(jq -sc 'map(.scope) | unique' "$WORK/sl/test-scope.jsonl")" = '["full"]'

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

# A python suite runs under an interpreter that imports pytest: the repo's .venv first, else
# python3, else python3.X on PATH newest first; none at all is one clear line. The toolbox holds
# every system binary but python, so no real interpreter answers.
mkdir -p "$WORK/tools" "$WORK/fakepy" "$WORK/py/tests"
for f in /usr/bin/* /bin/*; do
  case "${f##*/}" in python*|pydoc*) ;; *) [ -e "$WORK/tools/${f##*/}" ] || ln -s "$f" "$WORK/tools/${f##*/}" ;; esac
done
fake_py() { # name has-pytest
  printf '#!/bin/sh\n[ "$1" = -c ] && exit %s\necho "PASS: ran by %s"\n' "$([ "$2" = yes ] && echo 0 || echo 1)" "$1" >"$WORK/fakepy/$1"
  chmod +x "$WORK/fakepy/$1"
}
fake_py python3 no
fake_py python3.99 yes
fake_py python3.100 yes
fake_py python3.100-config yes
touch "$WORK/py/tests/test_p.py"
out=$(PATH="$WORK/fakepy:$WORK/tools" "$BASH" "$ROOT/share/run-suites.sh" --repo "$WORK/py" 2>&1)
assert grep -q 'PASS: ran by python3.100' <<<"$out"
mkdir -p "$WORK/py/.venv/bin"
cp "$WORK/fakepy/python3.99" "$WORK/py/.venv/bin/python"
out=$(PATH="$WORK/fakepy:$WORK/tools" "$BASH" "$ROOT/share/run-suites.sh" --repo "$WORK/py" 2>&1)
assert grep -q 'PASS: ran by python3.99' <<<"$out"
rm -rf "$WORK/py/.venv" "$WORK/fakepy"/python3.*
out=$(PATH="$WORK/fakepy:$WORK/tools" "$BASH" "$ROOT/share/run-suites.sh" --repo "$WORK/py" 2>&1)
assert test "$(grep -c 'no python with pytest' <<<"$out")" = 1
out=$(PATH="$WORK/fakepy:$WORK/tools" "$BASH" "$ROOT/share/run-suites.sh" --repo "$WORK/repo" 2>&1)
assert grep -q '2 PASS' <<<"$out"

printf 'PASS: %s asserts; run-suites runs the wave at nice 10 and wall-clock suites at the caller'\''s nice, in parallel, longest first, a worktree on branch B uses a sibling worktree on B else the main checkout, a python suite runs under a python that imports pytest, and a run leaves its progress pointer only while it lasts\n' "$asserts"
