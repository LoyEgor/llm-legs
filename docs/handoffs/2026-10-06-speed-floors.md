# Speed floors one night cannot close

Status: open — To: Harness Doctor

From night 20261006T032009Z-f253 run harness-speed-20261006T032930Z-7b67, ledger rows `time_floor:*`. Every
proposal below changes a floor, a class definition or a concurrency policy, so the fixer changed none of them.

`share/time_budget.py` budget, min/day: the 24 h to 2026-10-06 07:20 local, against the 12.4 h since 2026-10-05
19:00, after c4adcbb8 (room admission 5 → 10 night workers, slow layer) and 167787af (one reroute per run) landed.

| class | 24 h | since 19:00 | what is left |
|---|---|---|---|
| slot | 2518 | 331 | 052f ran 5 slots for 5 h with 10-12 queued; f253 holds 10 of 10 |
| suite_run | 2266 | 2115 | wave suites at nice 10 under the benchmark (e2c3ec43, tonight) |
| suite_wait | 464 | 243 | same cause; tail capacity left open in `wait-run-suites-slot-hogs` |
| retries | 283 | 87 | 132 min was the 8-attempt Codex chain before the cap; the rest are mid-run walls |
| hooks | 147 | 132 | Pre/Post Bash 91 of 147; the hooks area cuts one hook a night |
| locks | 39 | 20 | 30 min are background waits, see 3 |

1. **slot.** On f253 the waits split into 151 min `limit` with 10 slots allowed, 85 min at 5 and 66 min `room`.
   Workers are model-bound and suites have their own cap. Choose: raise the ceiling past the cores while
   `slot_room` finds room, or treat a queue behind the machine guard as the floor. A queue summed over N jobs
   launched at once overstates the night's makespan.
2. **retries.** After 167787af a retry is one rescue after a usage wall, which the 429 doctrine calls weather.
   Proposal: the class drops attempts that ended walled (`walled`, `attempt_rcs` in runs.jsonl), or a weather dismissal.
3. **locks.** 87 waits (29.7 min) were on `~/.llm-limits.json.lock`, held during `llm-limits.sh`'s merge for up
   to 56 s. Its writers are the refresh heartbeat, the statusline refresher and the menu, never a chat or worker tool
   call. Yet `budget()` moves every wait out of `tools`. Proposal: wait rows name their caller (blind spot
   `wait-caller-kind`). The other ~9 min are `worker-run wait` poll lag: `WAIT_POLL` is 5 s, and a builtin
   `exit_code` test every second between full checks would cut ~7 of them.
4. **hooks.** Floor 0 cannot be met while any hook runs, and Egor declined the dispatcher on 2026-10-05. Proposal:
   keep it for ranking only, or set the floor to the hook set that must stay.
5. **suite_run.** The floor is 60. Workers chose `-j 1` on 12 runs of 8-43 suites (320 min in 2 days). They also
   background `run-all` past the 600 s Bash cap and poll with a fixed `sleep 540-590`, overshooting the suite's end.
6. **workers-active.** Night 052f was 4 %, with 55 % of its wall in the slot queue before c4adcbb8. Since 19:00 it is 21 %.
