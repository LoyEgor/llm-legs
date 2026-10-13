# Heavy test_consistency / test_harness_doctor are load wall, not suite work

Status: settled 20261012T233034Z-3131: kept the wall price (Lost time is wall-clock overhead), gated the reopening instead: after its own fix a heavy suite returns only at 1.5x its CPU a run before that fix, so load-inflated wall alone stays quiet (test_test_health red on old code; both rows fixed-pending)

From night fixer `harness-speed-test-health-heavy-llm-legs-test-consistency-20261012T010239Z-1189`, 2026-10-12.
Rows `speed-test-health-heavy-test-consistency`, `speed-heavy-test-harness-doctor`.

## Evidence
- CPU per run is flat at the 10-10 audit floor: consistency 21-22 CPU-s (1.7 s test shell, the rest
  real product probes, no hot spot), harness_doctor 12.5 CPU-s (the doctor's own runs).
- Wall is contention: unsharded runs (slot_room refused shards: load1 > load15 + cores) are 81 % /
  76 % of runs at 24-58 s; sharded runs take 4-9 s. Run count is tests/affected fan-out.
- No sleeps; a grep content cache measured flat.

## Yours to decide
Price `heavy` (share/test_health.py) on CPU-s per run against the suite's last audit, not on
load-inflated wall, or dismiss these two rows. Cost: one judge change plus its test. Loss if not:
both rows reopen every loaded night with nothing to cut. Recommendation: price on CPU.
