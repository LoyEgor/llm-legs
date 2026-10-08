#!/usr/bin/env bash
. "${BASH_SOURCE%"${BASH_SOURCE##*/}"}lib/suite-journal.sh"
. "$(dirname "$0")/light_research_harness.sh"

# Batching: several --prompt-file run side by side and land under ONE citation header.
printf 'file:1 | "x" | the tracked file holds x\n' >"$WORK/q1-answer"
printf 'plain second answer\nhttps://example.test/two | "second page" | a link of the second unit\n' >"$WORK/q2-answer"
printf 'ANSWER-FILE: %s\nFirst question.\n' "$WORK/q1-answer" >"$WORK/prompt"
printf 'ANSWER-FILE: %s\nSecond question.\n' "$WORK/q2-answer" >"$WORK/prompt2"
: >"$WORK/gemini.log"
run --prompt-file "$WORK/prompt2"; rc=$?; assert test "$rc" -eq 0
assert test "$(grep -c '^profile=' "$WORK/gemini.log")" = 2
assert test "$(grep -c '^CITATIONS:' "$WORK/answer")" = 1
assert test "$(head -1 "$WORK/answer")" = 'CITATIONS: 1/1'
# Both header lines are counted across the batch and written once: a per-unit `LINKS:` carried into
# the body puts a stray count under every heading and leaves the answer with no aggregate.
assert test "$(grep -c '^LINKS:' "$WORK/answer")" = 1
assert test "$(sed -n 2p "$WORK/answer")" = 'LINKS: 1'
assert grep -qx 'LINKS: 1' "$WORK/out"
assert test "$(grep -n '^## Q1$' "$WORK/answer" | cut -d: -f1)" -lt "$(grep -n '^## Q2$' "$WORK/answer" | cut -d: -f1)"
assert grep -qx 'plain second answer' "$WORK/answer"

# One failed question fails the call: 3 beats 4 beats 0, and no answer file is left behind.
printf 'QUOTA-Q: the leg answers with a quota wall.\n' >"$WORK/prompt-quota"
printf 'UNAVAIL-Q: the leg dies without a quota marker.\n' >"$WORK/prompt-unavail"
printf 'Research the repository.\n' >"$WORK/prompt"
rm -f "$WORK/answer"; run --prompt-file "$WORK/prompt-quota"; rc=$?; assert test "$rc" -eq 3
assert grep -q '^OUTCOME: GEMINI_USAGE_LIMIT$' "$WORK/out"; assert test ! -e "$WORK/answer"
rm -f "$WORK/answer"; run --prompt-file "$WORK/prompt-unavail"; rc=$?; assert test "$rc" -eq 4
assert grep -q '^OUTCOME: GEMINI_UNAVAILABLE$' "$WORK/out"; assert test ! -e "$WORK/answer"
printf 'APIERR-Q: agy >= 1.2.6 exits 3 on a model API failure that is no quota wall.
' >"$WORK/prompt-apierr"
rm -f "$WORK/answer"; run --prompt-file "$WORK/prompt-apierr"; rc=$?; assert test "$rc" -eq 4
assert grep -q '^OUTCOME: GEMINI_UNAVAILABLE$' "$WORK/out"; assert test ! -e "$WORK/answer"
printf 'CREDITS-Q: agy >= 1.2.15 words a spent plan as a credits shortfall.\n' >"$WORK/prompt-credits"
rm -f "$WORK/answer"; run --prompt-file "$WORK/prompt-credits"; rc=$?; assert test "$rc" -eq 3
assert grep -q '^OUTCOME: GEMINI_USAGE_LIMIT$' "$WORK/out"; assert test ! -e "$WORK/answer"
rm -f "$WORK/answer"; run --prompt-file "$WORK/prompt-unavail" --prompt-file "$WORK/prompt-quota"; rc=$?; assert test "$rc" -eq 3
assert test ! -e "$WORK/answer"

# A later launch refused: the units already launched still land their answers under their own
# Q headings, the call keeps the launch's exit, and an --attach of a launched run keeps both.
printf 'ROUND: bogus\nThird question.\n' >"$WORK/prompt-refused"
rm -rf "$WORK/answer" "$WORK/answer.units"
run --prompt-file "$WORK/prompt2" --prompt-file "$WORK/prompt-refused"; rc=$?; assert test "$rc" -eq 4
assert grep -qx 'tracked Gemini answer' "$WORK/answer"
assert grep -qx 'plain second answer' "$WORK/answer"
assert grep -qx '## Q2' "$WORK/answer"; assert test "$(grep -c '^## Q' "$WORK/answer")" = 2
assert grep -qx "ANSWER: $(cd "$WORK" && pwd -P)/answer" "$WORK/out"
refused_run=$(sed -n 's/^RUN: //p' "$WORK/out" | head -n1)
rm -f "$WORK/answer"; attach --attach "$refused_run" --out "$WORK/answer"; rc=$?; assert test "$rc" -eq 4
assert grep -qx 'plain second answer' "$WORK/answer"
rm -rf "$WORK/answer" "$WORK/answer.units"
run --prompt-file "$WORK/prompt-refused"; rc=$?; assert test "$rc" -eq 4
assert grep -qx '## Q1' "$WORK/answer"; assert grep -qx 'tracked Gemini answer' "$WORK/answer"
refused_run=$(sed -n 's/^RUN: //p' "$WORK/out" | head -n1)
rm -f "$WORK/answer"; attach --attach "$refused_run" --out "$WORK/answer"; rc=$?; assert test "$rc" -eq 4
assert grep -qx '## Q1' "$WORK/answer"
rm -rf "$WORK/answer.units"
# The refused launch's OUTCOME line is the status the caller routes on, so an --attach repeats it.
printf '%s\n' researcher EXIT3 >"$WORK/pick-queue"
rm -f "$WORK/answer"
PICK_QUEUE="$WORK/pick-queue" run --prompt-file "$WORK/prompt2"; rc=$?; assert test "$rc" -eq 4
assert grep -qx 'OUTCOME: GEMINI_UNAVAILABLE' "$WORK/out"
refused_run=$(sed -n 's/^RUN: //p' "$WORK/out" | head -n1)
rm -f "$WORK/answer"; attach --attach "$refused_run" --out "$WORK/answer"; rc=$?; assert test "$rc" -eq 4
assert grep -qx 'OUTCOME: GEMINI_UNAVAILABLE' "$WORK/out"
rm -rf "$WORK/answer.units"

printf 'PASS: %s asserts; batched questions under one header and outcomes mapped to exits, the worst one winning a batch\n' "$asserts"
