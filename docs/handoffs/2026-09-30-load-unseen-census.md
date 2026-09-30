# Hand-off: what the unaccounted CPU of load:unseen was made of on the night of 2026-09-30

Status: open

For «Harness Doctor» (`share/harness-ledger.json` `owner`). Written 2026-09-30 by the night fixer
run harness-load-20260930T001649Z-57dc. Ledger row: `load-unseen-suites-statusline` (open).
Changed nothing but the ledger and this file.

## 0. The problem

`load:unseen` red since 2026-09-29 21:17: 6.3 of 10 cores in the last hour are busy × ncpu minus
the cores memlogd sees per process. The kernel took 39-59 % of CPU and new processes ran at
1 100-2 900 a second over the same hours (samples 00:01-02:34 and 03:16). The rule does what the
design (§3 "unaccounted CPU") says: it shows CPU that per-process sampling misses. Most of that
CPU is kernel time spent on fork and exec, so the number follows the fork rate.

## 1. Census

No root, so no dtrace or eslogger. A Python poll of `proc_listallpids` at about 1 100 polls a
second recorded each new pid with its parent and read the ancestor chain through `KERN_PROCARGS2`.
It caught about 1 400 new processes a second, which is close to the sampler's own rate (so the
poll saw most of them). Each process was put in the first class its ancestor chain matched:

| origin (60 s, 03:25-03:31 local) | new/s | share |
|---|---|---|
| test suites (`tests/`, `run-suites`, `run-all` in the chain) | 658 | 61 % |
| statusline (`statusline.sh`, its work and ports probes) | 215 | 20 % |
| hooks | 92 | 8.5 % |
| worker-run outside its CLI's hooks (supervise, watchdog, wait) | 62 | 5.8 % |
| review-bench | 42 | 3.8 % |
| everything else | < 12 | 1 % |

At that time, four night worktrees (`-claude`, `-gemini`, `harness-tests-…`, `llm-health-…`)
had `share/run-suites.sh` running at the same time. The sampler's `tests` field read 0.

Statusline journal, same hour: 5 243 renders over 5 sessions (1.5 a second, about one per 3 s per
session, which is `refreshInterval: 3`). Mean render wall time was 628 ms, and about 140 new
processes a second went to each render and its probes.

Hook journal, same hour: about 2 300 s of hook wall time in total. `review-flow-gate.sh verdict`
had the most: 568 s over 305 runs, 1.9 s each.

The 21:17-00:00 part of the episode ran before the night run started. This census cannot
attribute it.

## 2. What is ours to change, and whose it is

1. **Statusline, about 20 % and steady while sessions are open.** This is item 2 of
   `docs/handoffs/2026-09-28-harness-performance-fix.md` (still open). The fork cuts the contract
   allows (one `git status --porcelain=v2`, fewer jq runs, a longer work-probe TTL) go to whoever
   takes that item. A longer `refreshInterval` needs Egor's word (§6 there).
2. **Test suites, about 61 %, only while fixers or chats run suites.** The fixer preamble tells
   every run to finish with `tests/run-all`, so each night run adds one full parallel `run-all`.
   `nice 10` makes the suites yield CPU but does not remove the kernel's fork cost, and nobody
   waited on this CPU at 03:30. Recommendation: treat night-window `load:unseen` as workload and
   leave the limit where it is. If the night orchestrator should cap how many `run-all`s run at
   once, that is the night-run owner's decision. The owner's rule "parallel load beats serial"
   argues for no cap.
3. **Doctor blind spots** added to the ledger: `short-lived-origin` (Load cannot say which process
   tree the unaccounted CPU belongs to) and `headless-suites` (`tests running` and test-history
   never see a suite started by a `claude -p` session).

No dismissal is proposed. The row stays `open`, so the problem stays red, and no limit moved.
