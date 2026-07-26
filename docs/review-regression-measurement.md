# Does a review need a review of its own fixes?

An open measurement. Every review round here ends the same way: a reviewer reports defects, the
author fixes them, and the fixes go in **unreviewed**. That delta is the highest-risk code in the
change — written under time pressure, in exactly the places a reviewer just pointed at — and
nothing has ever measured how often it is wrong.

This file is the record. Append a round; do not rewrite earlier ones.

## Protocol

1. First pass reviews the diff. Record how many reviewers, which models, which efforts.
2. Fix what it found.
3. **Before the second pass reports, write down which functions the fixes touched.** Not after.
   Classifying a finding once you have seen it is how a fix-introduced defect becomes a
   pre-existing one. A finding counts as a REGRESSION only if it lands in that pre-registered
   list; everything else is code the first pass already had in front of it and missed.
4. Second pass reviews the fixed diff, blind — reviewers are not told which lines are fixes.
5. Append the round below: reviewers, findings, how many were regressions, how many were false.

## What the rounds are answering

- **Do fixes introduce defects at a rate worth a second pass?** A second pass roughly doubles
  review wall-clock, so it has to earn that.
- **Does a wider panel find what a narrow one missed?** Same diff, more reviewers, counted.
- **How often is a reviewer simply wrong?** A false finding costs a fix that breaks working code.

## Rounds

### Round 0 — 2026-07-26, commit 258f75a
First pass: gemini pro high, 3 real defects. Fixed. sol high then re-read the fixed code and
found one more that **the fix itself introduced** (a path-resolution priority inverted while
closing a resolution gap). Not pre-registered — classified after the fact, so weaker evidence
than the rounds below.

Regressions from fixes: 1. Reviewers: 2.

### Round 1 — 2026-07-26, the corpus-tooling diff (`repo` field, `cluster`, `frontier`)
First pass on 516 lines: sol high (codex/main), gemini pro high (gemini/work). 5 real defects,
all fixed, each fix test-verified to fail without itself.

Second pass on the resulting 798 lines, four reviewers with distinct lenses: sol xhigh on the
statistics and search, sol high on corpus integrity, gemini pro high on account plumbing,
gemini pro high auditing whether each new test proves its claim. Pre-registered key written
before any of them reported.

| | count |
| --- | --- |
| real defects found by the second pass | 11 |
| of those, **regressions the first pass's fixes introduced** | 3 |
| of those, code the first pass saw and missed | 8 |
| findings that were wrong on inspection | 1 |

The three regressions: a floor guard bypassed by the session-account fix; the account pool
consulted twice per attempt by the same fix; and a budget assertion in a new test that held
even with the filter it named deleted.

The one wrong finding claimed the pool returned the wrong account under the new opt-in;
reproducing it against stubbed pool output showed the code was right. Checking cost less than
"fixing" working code would have.

Also of note: the test-audit reviewer independently broke a copy of the tool to confirm that
nine of the new assertions really fail when the behaviour they name regresses. That is the only
check so far on whether this repository's tests are load-bearing, and it is worth repeating.

## Reading it so far

Two rounds, four regressions from fixes, both times found only because someone looked again.
That is not yet enough to price a mandatory second pass, but it is enough that "review, fix,
commit" should not be called reviewed. The cheap form — one fast cell re-reading only the fix
delta — is what the next round should try, so the cost of the answer stops being a full pass.

## Continuing this

The tier a diff deserves comes from `review-bench suggest`, which reads the working tree and
names T0–T3 from measured cell compositions. It has no notion of "already reviewed" yet: it
sizes the whole diff, not the part no reviewer has seen. Giving it that would need a receipt —
the tool recording which tree state a review covered — and until it exists, step 3 above is done
by hand.
