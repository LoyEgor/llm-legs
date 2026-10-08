# Speed floors that measure a settled policy

Status: settled 2026-10-08 (branch fix/speed-recoverable): slot priced by a lent-slot burst replay, suites by their p10
wall, workers active the parent of its parts with a derived floor and no row of its own — To: Harness Doctor

From night 20261007T213650Z-7b98 run harness-speed-time-floor-suite-wait; rows `time_floor:slot`, `:workers-active`,
`:suite_run`. Egor kept the night-worker ceiling at the cores on 2026-10-07, so no fixer has a lever on these
rows, yet each night they stay loud and draw a Speed fixer (7b67, 6769, 7b98) that writes the same note.

1. `slot` sums waits over jobs queued at once: 376 min in the 24 h to 2026-10-08 00:50 are 60 min of union, all
   `limit` at 10 allowed or `room` (load admission). Proposal: the class takes the union of queued intervals.
2. `workers-active`: night 7777 read 202 of 1035 min model (19.5 %); 349 min of its wall is that summed queue,
   without it 29 %. Proposal: a run's wall starts at its first CLI start.
3. `suite_run`: worker suites held 618 min in 24 h, 326 of them 516 single-suite iteration runs; the lever is
   per-suite speed, the standing suite audit (1220a279). Proposal: the suite audit owns the row, no Speed fixer.
