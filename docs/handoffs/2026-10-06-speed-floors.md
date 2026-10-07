# Speed floors one night cannot close

Status: open — To: Harness Doctor

From harness-speed runs 20261006T032930Z-7b67 and 20261006T234307Z-6769, ledger rows `time_floor:*`. Each
proposal changes a floor, a class definition or a concurrency policy, so no fixer changed one.

`share/time_budget.py day`, min/day over the 24 h to 2026-10-07 02:40 (the 10-06 07:20 reading in brackets):

| class | min/day | what is left |
|---|---|---|
| slot | 453 (2518) | all of it f253's burst at 06:33, ~20 workers against 10 slots |
| suite_run | 622 (2266) | covering runs of 20-60 suites; suite speed is the tests area's |
| retries | 99 (283) | usage walls rescued once each: weather |
| hooks | 76 (147) | Pre/Post Bash 51 of 76; the hooks area cuts one hook a night |
| suite_wait | 44 (464) | fixed: a run frees its slot at its last suite (6769) |

1. **slot.** A queue summed over N jobs launched at once overstates the night's makespan. Choose: a ceiling
   past the cores while `slot_room` finds room, or the night's makespan over its longest job as the measure.
2. **retries.** One rescue after a usage wall is weather under the 429 doctrine. Proposal: the class drops
   attempts that ended walled (`walled`, `attempt_rcs` in runs.jsonl), or a weather dismissal.
3. **locks.** ~30 min were background waits on `~/.llm-limits.json.lock` (refresh heartbeat, statusline,
   menu), yet `budget()` moves every wait out of `tools`. Proposal: wait rows name their caller (blind spot
   `wait-caller-kind`); `worker-run wait` poll lag (`WAIT_POLL` 5 s) is ~9 more.
4. **hooks.** Floor 0 cannot be met while any hook runs, and Egor declined the dispatcher on 2026-10-05.
   Proposal: keep it for ranking only, or set the floor to the hook set that must stay.
5. **workers-active.** f253 read 16 %, the slot burst and suites; 21 % over the last 24 h.
