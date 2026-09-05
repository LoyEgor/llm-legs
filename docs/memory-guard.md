# Memory guard (decision record)

`bin/memlogd` does not only log. Under memory pressure it acts, on one rule with no knobs.

## The rule

Trigger, both halves required, evaluated once per tick:

- system available RAM < **3072 MB**, AND
- the **fattest currently-registered agent process tree** > **1536 MB**, weighed as the summed RSS of
  its live **descendants** — never the root's own, since the root is never killed and memory no kill
  can free must not convict a tree.

Action: **SIGKILL that one tree's descendants**. The tree's root is spared.

On a kill that landed, memlogd writes a `KILLED` line into its day log and appends a `MEMGUARD`
record to the run directory of the agent it cut.

## Why 3072 / 1536

Neither number alone convicts, and that is the whole design. macOS keeps swapping long past the
point where a machine is comfortable, so "low memory" on its own is a state this machine lives in
for hours at a time — a guard that fired on it would kill working agents most days. A single fat
agent tree on its own is likewise ordinary: a review panel with several cells open legitimately
holds a couple of gigabytes and finishes fine.

- **3072 MB available** is below the band where the machine still swaps its way out on its own and
  above the point where the UI has already stopped responding. Above it, waiting is the better
  move; below it, something is going to die and the only question is what.
- **1536 MB for one tree** is above every healthy agent tree measured on this machine and below the
  runaway shapes that caused the freezes this guard exists for (the 2026-08-28 incident, where a
  review cell's own `pnpm test` fan-out took the machine down). It picks out a tree that is
  anomalous, not merely busy.

Neither threshold is an environment variable. A threshold an operator can turn down is a guard that
stops firing exactly when it is needed, and both numbers are claims about this machine that belong
in this record rather than in a shell profile.

## Why SIGKILL the descendants and spare the root

**SIGKILL, not SIGTERM**, because the trigger condition is that the machine is nearly out of RAM. A
polite signal asks a process to unwind, which takes time and often takes *more* memory first; under
this trigger there is no time to give.

**Descendants, not the whole tree**, because the root is what reports. For a `worker-run` run the
root is the **vendor CLI** — the agent itself (`.cli_pid`, see the registry section): its children
are the commands it runs, the fan-out among them, and it survives to see one of them die by signal 9
and to say so. For a review-bench cell the root is the launcher (`claudeb`, `codexb`, `geminib`,
`grokb`) whose exit the panel is waiting on. Killing the root turns a legible "your children were
killed under memory pressure" into a run that simply vanished — which is precisely the failure mode
the 2026-08-28 incident produced and this guard exists to make legible.

So the root survives, sees its children die, and *reports*. Two things make that report say why: the
`MEMGUARD:` line worker-run prints, and one sentence in `BRIEF_PREAMBLE` (`bin/worker-run`) that
every worker is launched with — a command that ended by signal 9 was killed by this guard, do not
rerun it as is, run one project's tests rather than the whole monorepo's or split the work. Without
it the agent reads a bare exit 137 and reruns the command that took the machine down.

**One tree per trigger**, the fattest — of the trees that have something to kill. A candidate is a
tree with at least one live, non-zombie descendant: pick the fattest tree outright and a childless
root wins the pick every tick, kills nothing, and the tree that *is* cuttable stands untouched while
the machine thrashes. Killing every tree over the ceiling would take out the innocent alongside the
runaway; the fattest candidate is the one whose death most reliably ends the pressure, and the next
tick re-evaluates — the next fattest goes then, if it did not.

## Where the pid registry comes from

memlogd builds its candidate list from two writers, each read through the seam that writer already
uses. No registry file of its own, because a third copy of "which agents are live" is a third thing
to go stale.

1. **`worker-run` runs** — `${WORKER_RUN_DIR:-~/.cache/claude-worker-runs}/<run-id>/meta.json`,
   field **`.cli_pid`** where present, falling back to **`.pid`**. `.pid` is the detached
   supervisor, written at launch; `.cli_pid` is the vendor CLI, written by `run_with_deadline` the
   moment it has the child's pid. The guard kills the root's *descendants*, so registering the
   supervisor makes the CLI a descendant and the agent dies with the hog — which is exactly what the
   2026-09-05 live test produced (run `claudeb-1788615828-30933-684d` came back a bare `EXIT 137`).
   `.pid` remains the fallback so runs started before `cli_pid` existed still have a root; skipping
   them would leave standing exactly the trees this guard is for. A run directory carrying an
   `exit_code` is over and is skipped whatever its metadata still says.

   The field is read with `grep -o '"cli_pid": *[0-9][0-9]*'` and then `tr -dc 0-9`. Two traps in
   that one line: `"pid":` with the quote and colon, never bare `pid`, because the same object
   carries `pid_started_at` and a looser match aims the guard at whatever process now wears the
   launch instant; and the **space after the colon**, which is how `jq` writes these files — a
   reader that assumed `"pid":N` shipped in round 1, passed a suite whose fixtures were hand-typed
   JSON, and matched nothing at all on a real `meta.json`. Every fixture here is written through
   `jq`, exactly as `worker-run` writes it.
2. **review-bench cells** — `<state_dir>/{benches,pool-runs}/<run-id>/pid-<cell artifact>`, one file
   per launched cell, holding the cell's process-group leader pid. `<state_dir>` is
   `${WORKER_STATS_DIR:-${CLAUDEB_DIR:-~/.claude-profiles/.claudeb}/worker-stats}`. The name follows
   the run dir's existing flat per-cell convention (`raw-<artifact>.json`,
   `usage-<artifact>.jsonl`, `agy-<artifact>.log`). Written by `run_streamed` in
   `share/rbench/launch.py` right after `Popen` and removed in its `finally`, so it covers every
   transport and cannot outlive its cell on any exit path — a registration that outlives its process
   aims the guard at whatever now holds that number.

Both sources are then intersected with one `ps -axo pid=,ppid=,rss=` snapshot: a stale registration
whose pid is no longer in the table yields no tree at all, and one snapshot answers for every
candidate, because a `ps` per candidate at incident cadence costs more than the guard saves.

**Every root must prove its identity**, because a registration is only ever a claim about a *number*
and nothing on disk retires it: a supervisor killed before it wrote `exit_code` leaves its pids
registered until the 7-day prune, and macOS hands the same numbers out again within the day — the
guard would then SIGKILL the children of whatever unrelated process inherited one. So the process
wearing the number must have *started* when the registration says it did: its start, `now` minus the
elapsed time `ps -axo pid=,etime=` reports, within **60 s** of the stamp its writer left
(`cli_pid_started_at` beside `cli_pid`, `pid_started_at` beside `.pid`; a review-bench cell file
carries no stamp, so its **mtime** answers — it is written right after `Popen`). Unverifiable — no
stamp, no `etime`, no `ps` at all — is **skipped**, never killed: fail safe is the only safe side
when the action is SIGKILL. `worker-run` judges the same pids by the same comparison
(`supervisor_running`, `PID_START_SLACK`).

## What the live test showed (2026-09-05)

Run `claudeb-1788615828-30933-684d`, against the real daemon:
`INCIDENT avail_mb=2726` → `KILLED avail_mb=3027 tree_rss_mb=1850 root_pid=31116` (9 pids) →
`RECOVERED`. The guard fired, the machine stayed usable, and `worker-run wait` printed the
`MEMGUARD:` line. Three readings worth keeping:

- **A cold allocator never trips it, and never froze the machine either.** A process that maps and
  touches 48 GB once does not move `avail` off ~4.3 GB: the kernel pages the untouched, never
  re-read pages straight out to swap and the tree's *resident* size stays small. Same physics both
  ways — this is why "some process allocated a huge amount" was never the freeze shape, and why the
  guard is right not to react to it.
- **A hot working set trips it immediately**, which is the shape that does freeze this machine: the
  kill landed at `avail 3027 MB` with a tree of `1850 MB` resident.
- **RSS counts resident pages only.** A tree partly paged out weighs less here than its footprint,
  so the ceiling is deliberately a statement about *hot* memory. Reading it as "total memory this
  agent asked for" would make both thresholds look far too low.

## Where the memguard file lives

In the run directory of the agent that was cut — `<run dir>/memguard`, append-only, one line per
kill (a long run can be cut more than once):

```
MEMGUARD <epoch> avail_mb=<n> tree_rss_mb=<n> agent=<id> root_pid=<n> killed=<pid,pid,...>
```

`agent` is the `worker-run` run id, or `<bench run id>/<cell artifact>` for a review-bench cell. The
day log's line carries the same fields under the `KILLED` marker.

Nothing is written when nothing died. A fat root with no descendants leaves the guard no move, and a
`KILLED` line for it would record a kill that never happened.

## How it surfaces in worker-run

`worker-run report` and `worker-run wait` both print, from `<run dir>/memguard`:

```
MEMGUARD: 2 descendants SIGKILLed under memory pressure (avail 2900 MB, tree 2100 MB); the run's own root was spared
```

It appears on every report shape — running, terminal, and the unknown-exit one — because a run can
be cut while still going and the line must not wait for an exit code that a torn run may never
produce.

## Agent process environment

Agents that this guard tracks are launched with `NX_PARALLEL=1` and `NX_DAEMON=false` in their own
process environment, and nowhere wider: `supervise()` in `bin/worker-run` exports them into the
setsid'd supervisor every vendor child inherits from, and `run_streamed` in review-bench merges them
into each cell's env at `Popen`. This is prevention rather than cure — a serial, daemonless nx keeps
one agent's fan-out from becoming the tree the guard has to cut down — and it deliberately does not
touch the machine's other builds.

## Tests

`bash tests/test_memlogd.sh` covers the threshold logic (both halves required; either alone does not
fire), that the root survives while its descendants die, that a run recording `cli_pid` is rooted
there — the CLI lives, its own children die — while a run carrying only `.pid` still roots at the
supervisor, the `memguard` file's contents, and the `MEMGUARD:` line in `worker-run report`/`wait`.
It also covers the identity check (a stamp far from the process's own start is skipped, the same
tree with a truthful stamp is cut, a record with no stamp and a cell file whose mtime is nowhere
near its pid's start are skipped), a tree fat at the root alone never costing its children their
lives, and a childless root never taking the pick from a tree that can be cut.
`bash tests/test_worker_run.sh` covers `cli_pid` and `cli_pid_started_at` reaching `meta.json` at
launch, the pid being the CLI's rather than the supervisor's and the stamp matching the CLI's own
elapsed time, and the preamble sentence reaching every launched brief. review-bench's `tests/test_review_bench.sh` covers
the per-cell pid file being written, holding the group leader, and being removed when the cell ends.
