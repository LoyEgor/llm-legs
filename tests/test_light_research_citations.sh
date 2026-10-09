#!/usr/bin/env bash
. "${BASH_SOURCE%"${BASH_SOURCE##*/}"}lib/suite-journal.sh"
. "$(dirname "$0")/light_research_harness.sh" || exit 1

# Every research prompt carries the answer contract, and each `path:line | "quote" | claim` line is
# checked against the file: verified lines stay where they were, failed ones move under UNVERIFIED.
printf 'alpha\nbeta gamma\ndelta\nepsilon\nzeta\neta\ntheta\n' >"$REPO/cited.txt"
git -C "$REPO" add cited.txt; git -C "$REPO" -c user.name=x -c user.email=x@y commit -qm cited
cat >"$WORK/cited-answer" <<'CITED'
Prose that carries no claim needs no citation line.
cited.txt:2 | "beta gamma" | line 2 names beta
cited.txt:5 | "beta    gamma" | three lines late, inside the tolerance and whitespace-normalised
cited.txt:6 | "beta gamma" | four lines late, outside the tolerance
cited.txt:1 | "no such text" | quote absent from the file
gone.txt:1 | "alpha" | no such file
CITED
printf 'ANSWER-FILE: %s\nResearch the repository.\n' "$WORK/cited-answer" >"$WORK/prompt"
run; rc=$?; assert test "$rc" -eq 0
assert test "$(head -1 "$WORK/answer")" = 'CITATIONS: 2/5'
run_id=$(sed -n 's/^RUN: //p' "$WORK/out" | head -1)
assert grep -q 'ANSWER CONTRACT' "$RUNS/$run_id/brief.launch"
unverified=$(grep -n '^UNVERIFIED:$' "$WORK/answer" | cut -d: -f1); assert test -n "$unverified"
for kept in 'line 2 names beta' 'inside the tolerance'; do
  assert test "$(grep -n "$kept" "$WORK/answer" | cut -d: -f1)" -lt "$unverified"
done
for moved in 'outside the tolerance' 'quote absent from the file' 'no such file'; do
  assert test "$(grep -n "$moved" "$WORK/answer" | cut -d: -f1)" -gt "$unverified"
done
assert grep -qx 'Prose that carries no claim needs no citation line.' "$WORK/answer"
assert grep -qx 'CITATIONS: 2/5' "$WORK/out"
assert test "$(grep -c 'beta gamma' "$WORK/out")" = 0

# A web page is a source, not an unresolvable path: an `http(s)://` citation is counted as a LINK,
# kept where it stands and never fetched — the trailing digits of a URL are not a line number.
cat >"$WORK/linked-answer" <<'LINKED'
https://example.test/pricing | "4.25% + $0.35" | the published card rate
https://example.test/docs/v2 | "Authorization and Capture" | the API has delayed capture
cited.txt:2 | "beta gamma" | line 2 names beta
gone.txt:1 | "alpha" | no such file
LINKED
printf 'ANSWER-FILE: %s\nResearch the repository.\n' "$WORK/linked-answer" >"$WORK/prompt"
rm -f "$WORK/answer"
run; rc=$?; assert test "$rc" -eq 0
assert test "$(head -1 "$WORK/answer")" = 'CITATIONS: 1/2'
assert test "$(sed -n 2p "$WORK/answer")" = 'LINKS: 2'
assert grep -qx 'LINKS: 2' "$WORK/out"
unverified=$(grep -n '^UNVERIFIED:$' "$WORK/answer" | cut -d: -f1); assert test -n "$unverified"
for kept in 'the published card rate' 'the API has delayed capture'; do
  assert test "$(grep -n "$kept" "$WORK/answer" | cut -d: -f1)" -lt "$unverified"
done

# A scheme in capitals names the same page: read as a file path it fails a citation for a path no
# checkout has, and the answer loses the link it rests on.
printf 'HTTPS://Example.Test/Pricing | "4.25%%" | the card rate\n' >"$WORK/upper-answer"
printf 'ANSWER-FILE: %s\nResearch the repository.\n' "$WORK/upper-answer" >"$WORK/prompt"
rm -f "$WORK/answer"
run; rc=$?; assert test "$rc" -eq 0
assert test "$(head -1 "$WORK/answer")" = 'CITATIONS: 0/0'
assert test "$(sed -n 2p "$WORK/answer")" = 'LINKS: 1'
assert grep -qx 'LINKS: 1' "$WORK/out"

# The search state is the caller's ask, read ONCE from the prompt header here and handed to
# worker-run as a flag. A state the vendor cannot reach is refused before an account is spent.
printf 'web: OFF\nResearch the repository.\n' >"$WORK/prompt"
rm -f "$WORK/answer"; : >"$WORK/gemini.log"
run; rc=$?; assert test "$rc" -eq 4
assert grep -q '^OUTCOME: MODEL_REFUSED$' "$WORK/out"
assert grep -q 'no switch that turns web search off' "$WORK/err"
assert test "$(grep -c '^profile=' "$WORK/gemini.log")" = 0
assert test ! -e "$WORK/answer"

printf 'WEB: maybe\nResearch the repository.\n' >"$WORK/prompt"
: >"$WORK/gemini.log"
run; rc=$?; assert test "$rc" -eq 2
assert grep -q 'names no state' "$WORK/err"
assert test "$(grep -c '^profile=' "$WORK/gemini.log")" = 0


printf 'PASS: %s asserts; the citation check with its UNVERIFIED block, its `LINKS:` count for web sources and headed on-disk answer, and the `WEB:` state read from the prompt header\n' "$asserts"
