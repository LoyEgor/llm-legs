# A split suite's daily cost: machine time or an agent's wait

Status: open — To: Harness Doctor

From night 20261006T233611Z-7777 run harness-tests-20261006T234311Z-79c1, ledger row `test_daily_cost-worker-run`.

- Since e5bd8fd1 (2026-10-03) the probe writes no row for a run with a run-suites journal row, and the Tests
  rules read only `test-history.jsonl`. They saw unjournaled runs, plus the rows the probe wrote while one run
  was live: the 17 h 22 min red was 22 rows of one 27-minute run. `load_tests` now reads `runs.jsonl` as well.
  The real 24 h figure for the `test_worker_run` family is ~66 000 s. `test_consistency`, `test_instruction_gate`,
  `test_statusline_hooks`, `test_night_run` (7 800-14 300 s) and `llm-limits` read red for the first time.
- Where the family's cost comes from (24 h to 2026-10-07 03:00):
  - named runs by workers: 42 %;
  - named runs of all 18 parts by chats: 29 %;
  - full runs: 10 %.
  That is ~30 family runs a day. Under load each part's wall is 4-6× its quiet minimum (quiet sum 884 s, CPU ~615 s).
- Design §4 states the 2 h limit as "one agent waiting on one suite". Since the 2026-10-01 split, `cost_line` sums
  18 parallel parts, which is machine time. At ~30 runs a day no speed-up gets that under 2 h: it would need under
  240 s summed per run.

Recommendation: judge a split family per run by the wall an agent waits (its slowest part), and keep the summed
machine time as its own watch. Changing that limit or the family rule is the owner's call, not a fixer's.
