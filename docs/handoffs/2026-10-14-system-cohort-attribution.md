# System cohort: births charged to the script under test, at a long-lived-newborn scale

Status: open
To: «System doctor» (`share/system-ledger.json` owner), carried by the next night. From: System fixer
system-system-20261014T001850Z-4f07.

`cohort` first scored 7 covered days on 10-14: 61 rows, 35 of them `tests/` suites and 7 tags renamed by
ba52e8be. Two effects in the judge decide most numbers:

1. **Script under test.** `causer` charges a newborn to the nearest own script, so what a suite does through
   `bin/worker-run`, `doctor-fix`, `night-run`, `light-research`, `codex-image` or `run-suites.sh` is that
   script's. Suites ran in 40 % of the 10-06..14 ticks (run-suites journal) but hold 88 % of worker-run's
   attributed births and 94-100 % of the others'.
2. **Scale.** A tick charges `births_s × seen / births_seen × dt`: a newborn alive at the 2 s window's end
   stands for 22-35 births/s over the whole tick (weighted, median). Long-lived children (a forked `sleep`, a suite, a poller) are seen nearly every time
   they are born, ms-lived ones almost never. worker-run: 4.3 seen per window → 91 births/s; a stub lifecycle
   (start, supervise, wait, report) execs 255 binaries, × 485 runs on 10-13 ≈ 1.4/s. The lever "waits of at
   least 1 s" makes a forked wait more visible, not cheaper; the sleep builtin removes it (memlogd, dc3ad859).

The `tests/` rows are what Harness Suite audits price and cut (252 `suite:` rows in `share/spend-ledger.json`,
most audited 10-13); worker-run, run-suites.sh, harness-doctor and Hammerspoon carry Harness CPU-audit rows
of 10-13. The renamed tags (`worker-run`, `run-suites.sh`, `llm-limits.sh`, `statusline.sh`, `night-run`,
`test_statusline_hooks.sh`, `test_consistency.sh`) and `system-doctor` hold 10-06/07 only.

Decide: a `tests/` ancestor takes the births of the script it drives, and `tests/` causes stay with Suite
audits; a seen newborn weighs by its parent's birth rate (census) rather than the tick's share; a legacy tag
folds into its cause. Until then a fork cut in a test-driven script cannot reach the proof's 25 %.
Per-cause measurements: this run's `open` rows in `share/system-ledger.json`.
