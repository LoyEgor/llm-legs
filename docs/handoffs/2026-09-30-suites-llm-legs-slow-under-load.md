# Hand-off: `suites · llm-legs` at 22 min is concurrent load, not a slower suite

Status: open

For the chat «Harness Doctor» (owner of `share/harness-ledger.json`). From night fixer run
`harness-tests-20260930T001649Z-7ba4` (night 20260930T001419Z-8480).

## What was flagged

`test_slow:llm-legs:suites`: a worker's full `tests/run-all` against the main checkout, started
2026-09-30 02:29:07 local and finished 02:51:12, took 1326 s against a usual of 577 s
(`test-history llm-legs suites 1790725872`). Logs: `$TMPDIR/run-suites.Te1JLU`.

## Why

- Four full llm-legs runs overlapped, each at `-j 5` on 10 cores, plus single-suite fixer loops
  (`test_instruction_gate`, `test_worker_pick`, `test_vendor_fingerprint`, `test_consistency`):

  | logdir | start | wall | summed suite time | failed |
  |---|---|---|---|---|
  | Kui8Dn | 02:24:32 | 2060 s | 7963 s | 4 |
  | Te1JLU (flagged) | 02:29:07 | 1320 s | 6506 s | 7 |
  | tXv84T | 02:38:00 | 1538 s | 6594 s | 5 |
  | (4th) | 02:39:42 | 1463 s | 5913 s | 6 |

  Quiet runs on 2026-09-29 21:28–23:26 took 540–636 s wall with 2084–2459 s summed.
- The flagged run's summed time tripled, and wall ≈ summed / 5, so it was throughput-bound. No
  suite regressed: every suite slowed in proportion, and the other three runs slowed the same way.
- Only the flagged run reached `test-history.jsonl`, so `suites_at_once` saw part of the peak.
  That gap is recorded as the `suites-journal-sampled` blind spot.
- The failures came from live WIP in the main checkout at the time. They are not part of this
  finding.

## What the design already says

`share/run-suites.sh` has no cross-invocation lock on purpose. Handoff
`2026-09-28-harness-performance-fix.md` §4 says not to add a cross-chat queue.

## Proposed to the owner

1. Dismiss this cause. The ledger row `suites-llm-legs-concurrent-load` stays `open`, narrowed to
   concurrent full runs. A fixer may not turn it into `not-a-bug`; only you can.
2. If the row should keep catching real regressions, the rule has to tell load from slowness,
   for example by skipping a run whose interval overlapped another full run of the same repository.
   That loosens the judge, so it is your call.
3. Fixing the blind spot means `run-suites` writes its own journal row at exit. That is a new
   writer, so it is your work, not a fix run's.
