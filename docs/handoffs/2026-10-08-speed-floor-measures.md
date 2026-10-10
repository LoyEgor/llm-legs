# Suite floor: what p10 can reach

Status: settled 20261010T031219Z-4c4e: all three in share/time_budget.py and bin/speed-doctor, the suite p10 per suite-file blob, only a run's free-machine part over its floor, the night judged on its own parts' floor share; live suite time over its floor 5851 -> 52 min/day, time_floor:suite_run and :workers-active fixed-pending

`slot` settled 2026-10-08 (lent-slot burst replay). Night 817e, run harness-speed-time-floor-suite-run, rows
`time_floor:suite_run` and `:workers-active` (98 % suites): 294 min/day over p10 once failed runs left the
sample; gap share 23 % of suite wall at load < 10, 48 % at 30+.

1. p10 spans 7 days of suites that keep gaining checks, so a quiet machine reads 23 % over. Proposal: p10 per
   suite blob, suite_audit's key.
2. The load-band excess, about 450 suite-min/day, is night workers at the cores and the owner's benchmark,
   both settled. Proposal: the row judges the quiet-band gap only.
3. `workers-active` judges the last night's share against a floor from the last 24 h of workers. Proposal:
   that night's own parts.
