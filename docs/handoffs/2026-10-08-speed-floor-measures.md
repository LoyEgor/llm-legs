# Suite floor: what p10 can reach

Status: open — To: Harness Doctor

`slot` settled 2026-10-08 (lent-slot burst replay). Night 817e, run harness-speed-time-floor-suite-run, rows
`time_floor:suite_run` and `:workers-active` (98 % suites): 294 min/day over p10 once failed runs left the
sample; gap share 23 % of suite wall at load < 10, 48 % at 30+.

1. p10 spans 7 days of suites that keep gaining checks, so a quiet machine reads 23 % over. Proposal: p10 per
   suite blob, suite_audit's key.
2. The load-band excess, about 450 suite-min/day, is night workers at the cores and the owner's benchmark,
   both settled. Proposal: the row judges the quiet-band gap only.
3. `workers-active` judges the last night's share against a floor from the last 24 h of workers. Proposal:
   that night's own parts.
