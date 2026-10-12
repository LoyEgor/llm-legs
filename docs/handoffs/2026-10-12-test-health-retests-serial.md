# Hand-off: dismiss opportunity:test-health/retests and test-health/serial

Status: open
To: «Harness Doctor»

Rows `speed-test-health-retests` and `speed-test-health-serial` in `share/harness-ledger.json` hold
the evidence. Retests: pass reuse on identical inputs was built and dropped 2026-10-07 (Egor: ~1 %
of suite CPU, do not rebuild), so every night re-picks a lever nobody may pull. Serial: the 15
one-slot runs all ended 10-05/06 and leave the window 10-13.

Proposed: dismiss retests (`not-a-bug`), or drop the lever from `bin/speed-doctor`; let serial
age out and close its row once the doctor reads it quiet.
