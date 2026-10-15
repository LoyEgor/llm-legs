# Legacy (direction 5)

Code and tests nothing needs: dead code, duplicates, and obsolete or duplicate test checks.

## Metric

Net lines in the four sweep repositories (llm-legs, claude-setup, review-bench, hammerspoon), with code and tests
counted apart (`git diff --shortstat <base>..HEAD`). A test check leaves only when it is:
- stale: it guards a case the code can no longer produce;
- or covered: another suite's check fails on the same mutation.

## State

- Since 2026-09-25 the four repositories grew ≈+117k lines: tests +53k, doctor and night code +29k.
- llm-legs `tests/` from 10-01 to 10-14: 69 → 167 files, 2.97 → 7.15 MB. Part of that is suite splits.

## Done

- Retired features took their tests with them:
  - llm-legs: `test_light_edit`, `test_land`, `test_worktree`, `test_night_report_trial`;
  - claude-setup: 5 files.
- 10-14: tests lens pilot on the 10 heaviest suites, two rounds (05a7238f, 62458120):
  - 131 fixes, +1,096 −803 = +293 lines;
  - the lens as it stands strengthens weak checks, which adds lines, so cleanup here is deletion only.
- 10-14: a tests round was added to the night's debt pass (9e852e4d). No night has run it yet.
- 10-14: the lens was tuned (review-bench 53f8137, 051aa8f).

## Decisions

- 10-14: unused code is deleted together with its tests, with no "Egor asked" marker.
- 10-14: a stale check is deleted, never strengthened.
- 10-14: a suite that caught no defect in 90 days is deleted whole (`uncaught:` in doctor-fix's suite audit).
- The sweep repositories land everything in main; nothing is kept back on a list.

## Records

`share/code-ledger.json` (Code doctor's dead and duplicate groups).
