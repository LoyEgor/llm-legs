# Speed floors one night cannot close

Status: settled 2026-10-07: Egor agreed to keep the night-worker ceiling at the cores; slots stay paced by load and memory admission, the suite, suite-wait and workers-active floors stay open as their own ledger rows

From night 20261006T032009Z-f253 (ledger rows `time_floor:*`). The hooks floor stays 0: a floor is plain Claude
Code's value, used for ranking. Suites, suite waits and workers-active stay open as their own ledger rows.

Left: the night-worker ceiling. `night_worker_slots` (`share/slots.sh`) admits 2..cores (cap 12); on f253 waits
split 151 min `limit` at 10 allowed, 85 min at 5, 66 min `room`. Slot minutes are summed over jobs queued at once,
so they overstate the night's makespan.

Cost: one line in `share/slots.sh` (ceiling past the cores while `slot_room` finds room) and its test.
Loss: up to ~150 min/day of summed slot queue on full nights; far less makespan.
Recommendation: keep the ceiling at the cores; load stood at 77 with 10 workers tonight, and shorter worker walls
shorten the queue without new contention.
