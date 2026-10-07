# A split suite's daily cost: machine time or an agent's wait

Status: settled 20261007T213650Z-7b98: cost_line costs a split family's run its slowest part (design §4: one agent waiting on one suite); summed machine time over 2 h stays a watch (test_harness_doctor)

From night 20261006T233611Z-7777 run harness-tests-20261006T234311Z-79c1, ledger row `test_daily_cost-worker-run`.

- Since e5bd8fd1 `load_tests` reads `runs.jsonl` too; the real 24 h figure for `test_worker_run` is ~66 000 s.
- Its cost (24 h to 2026-10-07 03:00): named runs by workers 42 %, named runs of all 18 parts by chats 29 %,
  full runs 10 %; ~30 runs a day, each part's wall 4-6× its quiet minimum under load (quiet sum 884 s).
- Design §4 states the 2 h limit as "one agent waiting on one suite", but since the 2026-10-01 split `cost_line`
  summed 18 parallel parts, which is machine time no speed-up gets under 2 h at ~30 runs a day.
