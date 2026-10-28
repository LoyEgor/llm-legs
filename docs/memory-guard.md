# Memory guard (decision record)

`bin/memlogd` does not only log. Every tick it runs `bin/chat-load` (deployed beside the daemon
copy in `~/.local/libexec/`), which attributes every process to the chat that launched it, writes the
per-chat load snapshot the llm-limits menu shows, and under memory pressure acts on one rule with no
knobs. A forced reboot is the one outcome this exists to prevent; lag and heavy swapping are fine.

## The rule

Trigger, both halves required, evaluated once per tick:

- system available RAM < **2048 MB**, AND
- the **fattest chat job** > **1536 MB**, weighed as the summed physical footprint of its members.

memlogd counts available RAM one of two ways (`available_mb`), and the `KILLED` line names which as
`trigger=ram|swap`, beside `swap_room_mb=`:

- **ram**: free + inactive + speculative pages, all RAM can hand out while swap can still grow;
- **swap**, once **swap room** is under **4096 MB** (free swap plus the free disk of the swap volume
  `/System/Volumes/VM`, `swap_probe`, logged as `swap_room_mb=` in `machine/`): free + speculative +
  purgeable pages + inactive × (file-backed − speculative) / (active + inactive), the file-backed
  share of the inactive pages. A failed probe (-1) or a vm_stat without a file-backed count keeps ram.

The same count opens and closes incidents, so the 1 s ticks run once it is low.

A member's weight is its `ri_phys_footprint` (`proc_pid_rusage`, one syscall per attributed pid), the
memory `top` and Activity Monitor show; a pid it cannot read (another user's, gone) keeps its RSS
from `ps`. RSS alone missed wired GPU memory: a headless Cycles render on Metal holds ~9 GB at
0.2 GB RSS. Tests weigh pids from `CHAT_LOAD_FOOTPRINT` (a JSON `{pid: KB}`) instead.

A **job** is one process group launched by one chat — every Bash call a chat makes is its own group
— minus every protected process, every process of another user (its kill could only fail) and every
process the guard SIGKILLed in the last 30 s (still dying under swap, not a new job). Action: **post
the notice, then SIGKILL every member of that one job** — the whole group at once when nothing else is
in it, so what it forked while the notice was in flight goes too. The next tick re-evaluates; the next
fattest goes then, if the pressure did not end. Only the memlogd LaunchAgent acts (launchd's
`XPC_SERVICE_NAME=com.egor.memlogd`, which guard tests set on purpose); any other `chat-load sample` run
prints `WOULD KILL chat=… job_pgid=… footprint_mb=…` and signals nothing.

On a kill that landed, chat-load prints a `KILLED` line memlogd appends to its day log, appends a
`MEMGUARD` record to the run directory of any worker run or review cell the job ran under, and the
menu shows a red `⚠ HH:MM guard killed a job of <chat> · freed N GB` row for 15 minutes.

## Who a process belongs to

Every process a chat launches inherits `CLAUDE_CODE_SESSION_ID`, and `worker-run` exports
`CLAUDE_LAUNCHER_SESSION` into every worker it starts. chat-load reads both from the kernel
(`KERN_PROCARGS2`, same user only), cached per pid, start time (reckoned from when `ps` ran) and command name, so an exec re-reads it. Order: the launcher, then the
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

A stale registration can only spare a process, never condemn one, so no identity check is needed.

So the agent always survives its command: the chat or worker CLI sees the command die by signal 9
and can say so, and a worker run's supervisor still writes its exit code and report.

## The notice comes first

Before the kill, chat-load posts a `notice` block (the deployed `report-bus`, all posts at once under
one 3 s timeout) to the
launching chat and to every live session a member ran under: what was stopped, why (the trigger and
the numbers), that this is not a crash and the task is still solvable, and not to start it again at that
size or in any variant near it: a rerun must need far less memory, or the task finishes without it and
reports that it needs a bigger machine. Posted first, it is already on the bus when the
killed tool call returns, so that call's own PostToolUse flush carries it into the model's context
and Egor's view. A closed chat gets no post — nothing may wait for a chat that never comes back —
but its job is still killed: that is exactly what nothing else would ever stop.

A worker session never flushes the bus (`skip_flush`, shared-invariants row `ch`), so a worker run's
own session gets the same text as a line in `<run dir>/inbox` (`by: memory-guard`), which
`bin/worker-inbox-hook.sh` hands a claudeb worker at its next tool call as a message from the memory
guard; other vendors' lines wait for a `RESUME` (`share/worker-inbox.sh`).

Nothing is paused or queued: SIGSTOP would park a chat for minutes and leave stopped processes
behind for chats that die. A killed job leaves nothing.

## Why 2048 / 1536

Neither number alone convicts, and that is the whole design. macOS keeps swapping long past the
point where a machine is comfortable, so "low memory" on its own is a state this machine lives in
for hours at a time. A single fat job on its own is likewise ordinary.

- **2048 MB available** is above the point where the UI has already stopped responding. It was 3072
  until 2026-10-19, when Egor lowered it: he takes a lagging Mac over killed work, and a local audio
  model of 5-8 GB was killed at 3072 run after run while the Mac stayed usable.
- **1536 MB for one job** is above every healthy agent job measured on this machine and below the
  runaway shapes that caused the freezes (a review cell's `pnpm test` fan-out; a chat's `nohup` bench
  loop, invisible to the old guard, which knew only registered worker trees).

Neither threshold is an environment variable: a threshold an operator can turn down is a guard that
stops firing exactly when it is needed. Both are stated once, in `bin/chat-load`; the swap room that
switches the count (`swap_reserve_mb`), once, in `bin/memlogd`.

## Why the count changes when swap is full, not the threshold

`avail` counts inactive pages as RAM to hand out, and an inactive anonymous page is that only while
swap can take it.

Raising the threshold instead was rejected (Egor, 2026-10-20: not above 2 GB): it kills healthy work
on a roomy disk, where the ram count is right.

- The file-backed share estimate errs toward keeping jobs.
- **4096 MB** of room is ~19 s at that night's fastest growth (6 GB of swap in 28 s), about ten
  incident ticks. It only switches the count: a full disk with RAM free still reads several GB
  available the swap way and opens no incident, so stale swap, the term that once latched the dumps
  for 14 hours, decides nothing.
- No per-chat hold for relaunches: the eight relaunches of that night were a worker that never heard
  the guard (see Notice).

## Why SIGKILL

The trigger is that the machine is nearly out of RAM. A polite signal asks a process to unwind,
which takes time and often more memory first; under this trigger there is no time to give. One job
per tick, the fattest: killing every job over the ceiling would take out the innocent alongside the
runaway.

## What the live test showed (old guard, same physics)

- **A cold allocation never trips it and never froze the machine either.** 48 GB mapped and touched
  once does not move `avail` off ~4.3 GB: the kernel pages it out and the resident size stays small.
- **A hot working set trips it immediately**, which is the shape that does freeze this machine.
- **RSS counts resident pages only**, so the ceiling was a statement about *hot* memory. The
  footprint the guard weighs now also counts compressed and wired pages (GPU buffers), so a job
  whose memory was swapped out still weighs what it would take back.

## The memguard file

In the run directory of a worker run or review cell the job ran under — `<run dir>/memguard`,
append-only, one line per kill:

```
MEMGUARD <epoch> avail_mb=<n> tree_rss_mb=<n> agent=<id> root_pid=<n> killed=<pid,pid,...>
```

`tree_rss_mb` (and the `KILLED` line's `job_rss_mb`) is the job's summed footprint; the key predates
it and stays for `worker-run`'s reader. `agent` is the `worker-run` run id, or `<bench run id>/<cell artifact>`; `root_pid` the nearest
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
the CPU and memory split (CPU from the delta of each process's cumulative CPU time between ticks;
`Mem <chats> chats + <other> other = <sum> GB · RAM <used> of <total> · swap <swap>`: chats and other
are footprint sums of every process, the sum their shown parts added, beside RAM used = total −
available; footprints count compressed and swapped pages at their uncompressed size, so the sum runs
past RAM used, and capping chats at it read other as 0.0 while two renders ran), the guard row, one aligned
line per chat — state, title shortened to 22 columns keeping a trailing PR/phase number, cores, GB,
a 15-minute CPU spark scaled to the performance cores — and what inside "other" chats may cause
indirectly (screen = WindowServer, kernel = kernel_task, signing = syspolicyd + trustd). States:
`needs CPU` (using ≥ 0.3 cores on a machine ≥ 90 % busy — the only state more CPU would speed up),
`full speed`, `wait model` (turn running, CPU near zero), `idle`, `closed` (chat gone, jobs alive),
`orphan` (below). A live chat's click raises its tab or copies its resume command. A `closed` or
`orphan` row opens a submenu instead: `Stop · <GB>` runs `chat-load stop <key>` (a closed chat also
keeps `Copy reopen command`).

**orphan** is what nothing runs any more and no chat claims: a process of Egor's adopted by launchd
(ppid 1) but not one of its jobs (`launchctl list`, asked only when a candidate exists, so apps never
qualify), an hour old or more, not under `/System/` nor an XPC service or extension, with no attributed
process in its tree (a detached bench waiting for its slot is a chat's work). It is shown by the same
50 MB / 0.05-core floor as a closed chat. First case, 2026-10-28: three `agy --print` runs of
find-truth's morning advice, hung for 3-5 days, 0.4 GB, invisible inside "other". A chat-launched
daemon that scrubs the session variables off its own environment (the nx daemon drops `CLAUDE_CODE_*`)
lands here an hour after the command that started it exits.

`chat-load stop chat:<session>|orphan:<pid>:<start>` works the members out again from the live table,
so a pid reused since the row was drawn is never touched: every process attributed to a chat that is
not open (an open one is refused), or the orphan's tree when its start still matches. SIGTERM; a child
born to a member while they shut down is added (a stopped `nx serve` started a fresh nx daemon on its
way out); SIGKILL whatever still runs after 5 s. It prints one line, which the menu shows as an alert.
Only Egor's click runs it; the guard never does. A chat's own worker runs and benches go with it:
the row counts them, and a closed chat cannot read their results.

A chat appears only by its title from
`share/chat_names.py` (`chat_title`: the name, else `untitled chat · <project> · <when>`), never an
id or a derived session name. Older than 120 s the title reads `· stale` in red: the guard is not
running.

## Nothing it runs lives on /Volumes/Work

`install-agent` deploys chat-load and every file it runs beside the daemon copy in `~/.local/libexec/`
(`install_agent` in `bin/memlogd`), and chat-load imports and runs those copies (the deployed bus sources
the lock library beside itself; without it every guard notice went to `lost.log` with the chat recorded as told). macOS denies a
LaunchAgent's Python /Volumes/Work, and every process that Python starts, even with memlogd itself
granted Full Disk Access. Every Harness doctor write run redeploys a landed edit of any of them (`harness-doctor --redeploy`).

## Agent process environment

Workers and review cells run with `NX_PARALLEL=1` and `NX_DAEMON=false` in their own environment
and nowhere wider (`supervise()` in `bin/worker-run`, `run_streamed` in review-bench): prevention,
so one agent's fan-out does not become the job the guard has to cut.

## Tests

`bash tests/test_memlogd.sh` runs the daemon against real process groups.

