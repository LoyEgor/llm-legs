# Memory guard (decision record)

`bin/memlogd` does not only log. Every tick it runs `bin/chat-load` (deployed beside the daemon
copy in `~/.local/libexec/`), which attributes every process to the chat that launched it, writes the
per-chat load snapshot the llm-limits menu shows, and under memory pressure acts on one rule with no
knobs. A forced reboot is the one outcome this exists to prevent; lag and heavy swapping are fine.

## The rule

Trigger, both halves required, evaluated once per tick:

- system available RAM < **3072 MB**, AND
- the **fattest chat job** > **1536 MB**, weighed as the summed RSS of its members.

A **job** is one process group launched by one chat — every Bash call a chat makes is its own group
— minus every protected process. Action: **post the notice, then SIGKILL every member of that one
job**. The next tick re-evaluates; the next fattest goes then, if the pressure did not end.

On a kill that landed, chat-load prints a `KILLED` line memlogd appends to its day log, appends a
`MEMGUARD` record to the run directory of any worker run or review cell the job ran under, and the
menu shows a red `⚠ HH:MM guard killed a job of <chat> · freed N GB` row for 15 minutes.

## Who a process belongs to

Every process a chat launches inherits `CLAUDE_CODE_SESSION_ID`, and `worker-run` exports
`CLAUDE_LAUNCHER_SESSION` into every worker it starts. chat-load reads both from the kernel
(`KERN_PROCARGS2`, same user only), cached per pid and start time. Order: the launcher, then the
process's own session, then the nearest ancestor that claims one or is a registered chat CLI, then
the process's own registry entry (a top-level CLI carries neither variable). The session found is
then walked up to the outermost chat, so a worker's job is billed to the chat that launched it.

macOS hides the environment of platform binaries (`/bin/*`, `/usr/bin/*`), so a shell or `sleep`
is attributed through its ancestry alone. The hogs that froze this machine — python, node — expose
theirs, so even one orphaned to launchd still has an owner.

**What no chat launched is never a candidate**: Egor's apps and shells carry no session variable and
have no chat ancestor. There is no vendor or CLI name list anywhere; the registries below decide.

## Protected

The registry pids and all their ancestors are never members of a job:

1. live chat CLIs — `~/.claude-profiles/*/sessions/<pid>.json` and `~/.claude/sessions/<pid>.json`
   (`CHAT_LOAD_SESSIONS` in tests);
2. `worker-run` runs without an `exit_code` — `meta.json` `.cli_pid` and `.pid`
   (`${WORKER_RUN_DIR:-~/.cache/claude-worker-runs}`);
3. review-bench cells — `<state_dir>/benches/<run-id>/pid-<cell artifact>`, `<state_dir>` being
   `${WORKER_STATS_DIR:-${CLAUDEB_DIR:-~/.claude-profiles/.claudeb}/worker-stats}`, written right
   after `Popen` and removed in its `finally`.

A stale registration can only spare a process, never condemn one, so no identity check is needed:
the old guard's start-time verification existed because a registered pid used to be a kill TARGET.

So the agent always survives its command: the chat or worker CLI sees the command die by signal 9
and can say so, and a worker run's supervisor still writes its exit code and report.

## The notice comes first

Before the kill, chat-load posts a `notice` block (the deployed `report-bus`, all posts at once under
one 3 s timeout) to the
launching chat and to every live session a member ran under (the worker's own, for a worker's job):
what was stopped, the available RAM, that this is not a crash and the task is still solvable, and to
rerun with fewer parallel jobs or smaller batches. Posted first, it is already on the bus when the
killed tool call returns, so that call's own PostToolUse flush carries it into the model's context
and Egor's view. A closed chat gets no post — nothing may wait for a chat that never comes back —
but its job is still killed: that is exactly what nothing else would ever stop.

Nothing is paused or queued: SIGSTOP would park a chat for minutes and leave stopped processes
behind for chats that die. A killed job leaves nothing.

## Why 3072 / 1536

Neither number alone convicts, and that is the whole design. macOS keeps swapping long past the
point where a machine is comfortable, so "low memory" on its own is a state this machine lives in
for hours at a time. A single fat job on its own is likewise ordinary.

- **3072 MB available** is below the band where the machine still swaps its way out on its own and
  above the point where the UI has already stopped responding.
- **1536 MB for one job** is above every healthy agent job measured on this machine and below the
  runaway shapes that caused the freezes (2026-08-28: a review cell's `pnpm test` fan-out;
  2026-09-28: a chat's `nohup` bench loop spawning tracers and node, invisible to the old guard,
  which knew only registered worker trees — 35 minutes frozen, then the power button).

Neither threshold is an environment variable: a threshold an operator can turn down is a guard that
stops firing exactly when it is needed. Both are stated once, in `bin/chat-load`.

## Why SIGKILL

The trigger is that the machine is nearly out of RAM. A polite signal asks a process to unwind,
which takes time and often more memory first; under this trigger there is no time to give. One job
per tick, the fattest: killing every job over the ceiling would take out the innocent alongside the
runaway.

## What the live test showed (2026-09-05, old guard, same physics)

`INCIDENT avail_mb=2726` → `KILLED avail_mb=3027 tree_rss_mb=1850` (9 pids) → `RECOVERED`.

- **A cold allocation never trips it and never froze the machine either.** 48 GB mapped and touched
  once does not move `avail` off ~4.3 GB: the kernel pages it out and the resident size stays small.
- **A hot working set trips it immediately**, which is the shape that does freeze this machine.
- **RSS counts resident pages only**, so the ceiling is a statement about *hot* memory.

## The memguard file

In the run directory of a worker run or review cell the job ran under — `<run dir>/memguard`,
append-only, one line per kill:

```
MEMGUARD <epoch> avail_mb=<n> tree_rss_mb=<n> agent=<id> root_pid=<n> killed=<pid,pid,...>
```

`agent` is the `worker-run` run id, or `<bench run id>/<cell artifact>`; `root_pid` the nearest
registered ancestor of the killed pids. `worker-run report` and `wait` print it on every shape,
running included:

```
MEMGUARD: 2 descendants SIGKILLed under memory pressure (avail 2900 MB, tree 2100 MB); the run's own root was spared
```

`BRIEF_PREAMBLE` in `bin/worker-run` tells every worker that a command ending by signal 9 was this
guard.

## The menu snapshot

`~/Library/Logs/memlogd/chats.json`, rewritten every tick and read by `appendChats` in
`hammerspoon/llm-limits.lua`. Title `Chats/other  <cores>/<cores> cores · <GB>/<GB> GB`; inside,
the CPU and RAM split (CPU from the delta of each process's cumulative CPU time between ticks; RAM
used = total − available, chats' RSS capped at it, other = the rest), the guard row, one aligned
line per chat — state, title shortened to 22 columns keeping a trailing PR/phase number, cores, GB,
a 15-minute CPU spark scaled to the performance cores — and what inside "other" chats may cause
indirectly (screen = WindowServer, kernel = kernel_task, signing = syspolicyd + trustd). States:
`needs CPU` (using ≥ 0.3 cores on a machine ≥ 90 % busy — the only state more CPU would speed up),
`full speed`, `wait model` (turn running, CPU near zero), `idle`, `closed` (chat gone, jobs alive).
A click copies the chat's resume command. A chat appears only by its title from
`share/chat_names.py` (`chat_title`: the name, else `untitled chat · <project> · <when>`), never an
id or a derived session name. Older than 120 s the title reads `· stale` in red: the guard is not
running.

Limiter holds (`docs/harness-doctor-design.md` §12) live here too, attributed like CPU and RAM: a
live hold (its pid started no later than `since` + 2 s) adds `⏳<jobs> <longest wait>` to the row of
the chat its waiting process belongs to, and one no chat launched gets its own `queued <limiter>` row.
Per limiter the snapshot keeps `moved`, the last tick a hold file of that limiter disappeared (a job
got its slot) or the queue first appeared; a queue none left for `QUEUE_STUCK_S` (1800 s) is stuck —
however long a job waits in a queue that moves, it stays dim. A stuck queue paints its row and the
`Chats/other` title red, and `queues[]` (`limiter, session, count, longest, moved_at, stuck, text`)
plus `queue_stuck_s` carry the verdict to the menubar ⚠ and the Harness doctor.

## Nothing it runs lives on /Volumes/Work

`install-agent` deploys `chat-load`, `chat_names.py`, `report-bus` and `report_frame.py` beside the
daemon copy in `~/.local/libexec/`, and chat-load imports and runs those copies. macOS denies a
LaunchAgent's Python /Volumes/Work, and every process that Python starts, even with memlogd itself
granted Full Disk Access (seen live 2026-09-28: titles and the bus probe both refused after the
grant). Re-run `bin/memlogd install-agent` after editing any of the four.

## Agent process environment

Workers and review cells run with `NX_PARALLEL=1` and `NX_DAEMON=false` in their own environment
and nowhere wider (`supervise()` in `bin/worker-run`, `run_streamed` in review-bench): prevention,
so one agent's fan-out does not become the job the guard has to cut.

## Tests

`bash tests/test_memlogd.sh` runs the daemon against real process groups (the fake `ps` lists only
the groups a case spawned): both halves required, a chat's own Bash job killed whole with its CLI
standing and the notice posted while the job was alive, registered CLIs, supervisors and cells and
their ancestors protected, an ended run protecting nothing, only the fattest job cut, unattributed
processes never touched, a fat CLI never convicted on its own weight, a worker's job billed to the
launching chat with both sessions notified, the `memguard` record and the `MEMGUARD:` line, and the
menu snapshot's aligned rows.
