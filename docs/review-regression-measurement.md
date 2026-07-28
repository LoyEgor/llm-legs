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

### Round 2 — 2026-07-26, two commits: `72b876b` (transcriptions-gpt input-device) and `3865199` (llm-legs iPad automation)

First pass: `review-bench review --tier T2` on each commit, 8 raters and 6 raters respectively
(the four opus/sonnet cells were skipped as unaffordable). 38 claims total, adjudicated by two
independent judge passes per run (sol high on codex/main and codex/work) per
`review-adjudication.md`; the orchestrator broke the four splits against the sealed code. 10 real
defects (7 daemon, 3 Hammerspoon), 24 false, 4 duplicates. Recorded as
`20260726T160350Z-72b876b` and `20260726T160350Z-3865199`.

All 10 fixed, then the fix surface was pre-registered by function name BEFORE any second-pass
reviewer reported. Second pass was the cheap form this file asked for: three reviewers reading
only the fixed units, blind — sol high (codex/main) and gemini pro high (gemini/work) on the
daemon, sol high (codex/work) on the Hammerspoon side.

| | count |
| --- | --- |
| real defects found by the second pass | 10 |
| of those, **regressions the first pass's fixes introduced** | 3 |
| of those, code the first pass saw and missed | 7 |
| findings rejected on inspection | 4 |

The three regressions were all in the daemon, all in pre-registered functions, and all in the
same fix: the refresh permission was computed at request start instead of at the refresh point,
so a take starting in that window still lost its PortAudio stream; the "ok queued" reply was set
before the request was enqueued, letting a later request overtake an earlier one and break the
FIFO/last-wins contract the fix had just introduced; and a failed or timed-out request bumped the
resolution generation without publishing a replacement, stranding the reported device at
`resolving (...)` forever. The Hammerspoon fixes introduced none.

The seven missed defects are the more interesting half. The loudest: `NativeMicRecorder`'s
device selection — which runs between the hotkey and capture start — still enumerated PortAudio
devices and called `_terminate()`/`_initialize()` inline. The first pass had named that hazard
elsewhere and the fix closed it in the resolver only, leaving it in the hottest path in the
repository. Also missed: an open stream leaked when `stop()`/`abort()` raised, the ffmpeg
default-fallback inheriting an already-spent capture deadline, the picker dictation path setting
its in-use flag after opening the recorder, and on the Lua side an overlay module whose `init`
performed side effects on load — the same class of bug as the headline defect the first pass did
catch, one file over.

Two of the four rejections are worth recording because both judges' framing mattered: a claim
that numeric device indices regressed described behaviour that predated the feature, and a claim
that a repeated manual menu click re-fires its action described the manual fallback's entire
purpose.

### Round 2 — 2026-07-27, the review-receipt diff (receipt, statusline segment, suggest delta)
First pass on ~310 changed lines: sol high (codex/work4) + gemini pro high (gemini/main),
6 unique defects (1 found by both). All fixed in one follow-up session; fix areas
pre-registered before the second pass.

Second pass, blind, one reviewer (gemini pro high): 1 real defect — an unguarded
`subprocess.run(cwd=...)` on a receipt whose recorded repository path no longer exists.
Against the pre-registered key it is NEITHER a regression from the fixes NOR a first-pass
miss: sol's first pass had reported it, and the orchestrator dropped that half of the
finding while consolidating six findings into the fix brief.

| | count |
| --- | --- |
| regressions the fixes introduced | 0 |
| first-pass misses found by the second pass | 0 |
| findings lost between review and fix brief | 1 |

New failure class for this experiment: **consolidation loss** — a finding survives review
and dies in the orchestrator's summary. The second pass is currently the only thing that
catches it; a cheaper guard would be diffing the fix brief against the first-pass findings
list before dispatch.

## Reading it so far

Three rounds, seven regressions from fixes, every one found only because someone looked again.
That is enough to stop calling "review, fix, commit" reviewed. Round 2 also priced the cheap
form the previous round asked for: three reviewers reading only the pre-registered fix units cost
roughly a third of the 14-rater first pass and returned as many real defects as it did — but
only 3 of its 10 were regressions. The rest were defects the wide first pass had in front of it
and missed, which suggests the second pass earns its keep less by auditing the fixes than by
being narrow: a reviewer told which functions matter reads them properly, where a broad panel
samples a whole diff and skims each unit.

If that holds in later rounds, the conclusion is not "always double-review" but "spend the second
pass as a focused re-read of the units the first pass touched", which is cheap enough to be
routine.

## Continuing this

The tier a diff deserves comes from `review-bench suggest`, which reads the working tree and
names T0–T3 from measured cell compositions. It has no notion of "already reviewed" yet: it
sizes the whole diff, not the part no reviewer has seen. Giving it that would need a receipt —
the tool recording which tree state a review covered — and until it exists, step 3 above is done
by hand.

## Round 4 — pre-registration (2026-07-28, clean-review detector)

First pass: T1 worktree review of the widened clean-review detector (run
20260728T104914Z-0917a9a, 11 cells, 19 raw findings, 5 fix-worthy). Fix units, registered
before the second pass reports:

1. `CLEAN_CONTRAST_TOKENS` — added though/although/yet/nevertheless/nonetheless/that said.
2. `CLEAN_DEFECT_VERBS` — new list (breaks/drops/leaks/… + incorrect/wrong/improper adverb
   forms), folded into both `CLEAN_ANNOUNCE_BLOCKERS` and `CLEAN_PROSE_BLOCKERS`.
3. `clean_review_sentences` — newline is now a sentence boundary; fragments without a word
   character are dropped.
4. `announce_clean_review` / `prose_clean_review` — casefold removed from both path checks.
5. `CLEAN_ANNOUNCE_PATH_RE` — announce preamble path test narrowed to dotted names only.
6. `tests/test_review_bench.sh` — the review's counterexamples pinned as must-error cases plus
   `**No issues found.**` as must-clean.

Second pass: one reviewer, focused re-read of these units only (the round-2 conclusion applied).

Round 4 outcome: the focused second pass (one reviewer, fix units only, every candidate string
executed before reporting) returned 3 confirmed P1 holes left open by the fixes — bare
infinitive defect verbs ("can break"), assertion verbs missing has/have/contains/remain
("has defects"), and a defect noun surviving inside a praise sentence ("handles requests,
defects remain") — plus one recall nit ("problems" absent from the defect-noun list). Zero
regressions introduced by the fix units themselves. Classification: all three are
incomplete-fix holes, not regressions and not first-pass misses (the first pass had no such
strings in front of it; the second pass manufactured and executed them). The focused-re-read
form again paid for itself: ~120 executed adversarial strings against six registered units.
