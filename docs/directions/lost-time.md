# Lost time (direction 2)

Wall-clock the harness adds to chats and workers: test runs and their queues, slot waits, Bash-cap reruns, hook
latency, wrap-up, retries, usage walls.

## Metric

The Lost time index in the Doctors menu: overhead per unit of work against the previous 7 days, where 1.00 means
unchanged. Read it with `share/time_budget.py day [--json]`; the day history since 2026-10-03 is in
`~/.cache/harness-doctor/budget-days/`. For a single suite, CPU is the honest number, since wall time follows the
machine's load.

## Done

| date | change | result | evidence |
|---|---|---|---|
| 10-01 | `test_worker_run` (7,755 lines) split into 16 suites | slowest part 2,287 → 233 s | 8f113a19 |
| 10-04 | workers run only the covering suites (`tests/affected`) | | ad5d95f9 |
| 10-05 evening, night 052f with a chat | slot admission, fixed sleeps removed, `test_instruction_gate` split in 8, the answer-pty hang, the slot_wait orphan race | median suite run 160–240 → 35 s at ×1 cost; the model night | c4adcbb8, 03001c01, 6389e500 |
| 10-08 | a chat's full `run-all` only on Egor's word | | 847c18ad |
| 10-10 | lifecycle, outcomes, consistency sharded | | |
| 10-13/14 nights | 252 suite audits (170 cut, 81 kept, 1 trade, `suite:` rows of `share/spend-ledger.json`); on 10-13, 166 tests touched, 72 faster and 41 slower | 59 → 50 min a pass, below day-to-day noise, at ×4.5 the 10-05 cost | |
| 10-14 | tests run once, when the work is done | runs per worker task 7.6 → 3.5 on 13 workers; recheck 10-17 on 40+ | 8e6961df |

## Open (priced, not proven)

- `run-all` killed at a worker's 25-min Bash cap and rerun: 61 a week, ≈194 min/day estimated from 30 days before
  the tests-once rule (`tool-idea-run-all-attach`, 0a9c7adb).
- Fixed-sleep polls of background jobs: ≈121 min/day estimated (`tool-idea-wait-until`).
- 5,800 suite runs a day across 469 suites (`tests/affected` fan-out).
  - A new file with no catch history is matched by its basename. The 7 new files of `docs/directions/` (README.md,
    system.md…) selected 38 suites on 10-15, and none of them reads those files.
- Expected gains have been inflated: on 10-14 the night expected 3,493 min/day from tests, while the whole tests
  row is ≈550. Price from the journal and prove on the index.

## Decisions

- Speed never trades model, effort or thinking.
- Never shorten a sleep or timeout a race check depends on: the 10-05 cuts that did went vacuous and were reverted.
- The statusline refresh stays 3 s; only the per-render cost is cut.
- Tests run once, and a full `run-all` only on Egor's word.
- Obsolete test checks belong to Legacy.
