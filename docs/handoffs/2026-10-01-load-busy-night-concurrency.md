# Hand-off: `load:busy` at 96 % is concurrent night run load, not an idle CPU leak

Status: open

For the chat «Harness Doctor» (owner of `share/harness-ledger.json`). From night fixer run
`harness-load-20261001T020658Z-45f1` (night 20261001T020350Z-7640). Ledger row:
`load-busy-night-concurrency` (open).

## What was flagged

`load:busy`: CPU 96 % busy in the last hour, usual under 70 % (limit 90 %); value 0.962.
Measured by `bin/harness-doctor:2363` off `samples.jsonl` host_statistics ticks.

## Why

In the 1-hour window (04:15–05:15 local):
- Mean CPU busy was 96.2 % (11 samples: 80.3 % to 100.0 %).
- Kernel CPU was ~31 % of total machine time.
- New process rate was 427 to 1 358 /s.
- Visible process cores in memlogd: 0.9 to 5.6 cores.
- Unaccounted CPU (`load:unseen`): mean 5.5 cores (limit 5.0).

Active processes on the 10-core host:
- Four night worktrees active simultaneously under night orchestrator `20261001T020350Z-7640`:
  - `claude` session (`night-20261001T020350Z-7640`)
  - `agy` worker (vendor release `claude-20261001T020602Z`)
  - `geminib` fixer (`harness-load-20261001T020658Z-45f1`)
  - `worker-run` supervising background tasks (`codex-1790820738-87828-36a5`)
  - `logo-vectorizer-bench` running `inkvec` multi-threaded vectorization
  - Parallel test suites (`tests/run-all`, `run-suites.sh -j 5`) across worktrees

## Relationship to load-unseen-suites-statusline

`load:busy` and `load-unseen-suites-statusline` are twin signals of the same condition:
- `load:unseen` captures the fork/exec and kernel cost of short-lived processes (census showed
  61 % test suites, 20 % statusline).
- `load:busy` captures total CPU utilization across all cores, saturated by concurrent night
  worktrees running test suites and model workers.

## Proposed to the owner

1. Keep this row `open` as recognized workload during the night window. The ledger row
   `load-busy-night-concurrency` stays `open`, narrowed to concurrent night runs. A fixer may not
   turn it into `not-a-bug` or raise `LIMITS["busy"]`; only the owner may.
2. If `load:busy` should not alert during scheduled night runs when multiple workers are
   expected to fully utilize the machine, the rule could distinguish night run windows or
   account for active worker count. That loosens the judge, so it is the owner's decision.
