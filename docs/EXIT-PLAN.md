# EXIT-PLAN — temporary scaffolding and its dismantling

**The inventory is empty: nothing in this repository is temporary right now.**

The shadow-trial stack this file inventoried (`llm-limitsd`, the shadow feed, the divergence
watch, their launchd jobs and suites, and the full `e2e_surfaces.sh` inside the daily
selfcheck) was dismantled on 2026-08-09. The last entry — the marker file that held robot
curl refreshes off while the experiment ran — was closed on 2026-09-02: the curl token
path is vendor-blocked for automation (150/150 robot and 18/18 user-bidden refreshes 429'd,
while an interactive session rotates instantly), so the robot half of that path is now
permanently off in code, the marker is gone, and there is no switch left that could turn it
back on. Rotation for automation is `claudeb revive` (`bin/claude-session-driver`), which the
`bin/llm-refresh` heartbeat escalates to; the menu's explicit refresh path still POSTs the token
endpoint when the user asks for it.

Whatever lands here next follows the same contract: an entry in `EXPERIMENTS.json` with a
review date the registry suite enforces, the surfaces it is visible on, and a `how_to_remove`
that ends with nothing left behind.
