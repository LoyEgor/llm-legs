# Log audit leftovers, night 4c4e

Status: open — To: next night (Harness Doctor owner); each item is ledger row `log_audit:<id>`, its note the verdict.

1. **token-map** (chat «Token spending tracking and optimization»): `tests/test_tracking.py` `TestMergedSplit` fails in any
   `.claude/worktrees/` checkout (5 tests, `merged-splits.json` FileNotFoundError; green in the main checkout), so every
   worker on a token-map worktree re-diagnoses it. Row `known-red-suites-rediagnosed`.
2. **Judge, owner's call**: `test_daily_cost` sums suite wall seconds, which night load inflates 2-5x; pricing it by
   the journal's CPU would stop fixers sharding against load. A metric change loosens the judge, so it is the owner's.
   Row `speed-doctor-metrics-misleading`.
3. Ruled out as harness bugs, dismissal proposed (the rest of nights 7777/817e settled in fea5e1fd):
   - model conduct, no component: `spend-menu-spec-churn`, `foreground-call-hangs-25min` (same cause as
     `hung-commands-25min-timeout`).
   - finished process: `classifier-output-noise` (experiment batches; `tokenmap kinds` reads one key and finds the
     array inside a fence).
   - logo-vectorizer-bench lane: `slot-throttle-foreground-sleeps`.
   - by design: `parallel-fixers-duplicate-work` (slots paced by load, each job rebased at landing).
   - weather: `suites-timeout-under-night-load` (load 165-350), `launch-into-exhausted-limit` (a chat's own wall;
     worker-run reroutes a walled worker).
