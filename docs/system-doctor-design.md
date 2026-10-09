# System doctor — design

## Why (2026-10-03 research, 2026-10-04 privileged sample)

The Mac is never idle and feels slow. Agent time is Speed's (`share/time_budget.py`). This doctor
is about the machine: process births, kernel CPU, memory compression and swap, SSD writes, free
space, crashes and reboots. It names our own code as a cause wherever a counter allows it. It
reports Apple and third-party causes and never fixes them.

Sources: `~/.cache/doctors/system-research/` (integrated.md, modules m1–m5,
privileged/analysis-*.md). They were measured on 2026-10-03 at load 50–186 and on 2026-10-04 with root.

## Settled facts

1. **Spawn storm, mostly our own bash.** Births ran at 1,150–1,430/s, confirmed by three
   independent methods. The 7-day day-medians were 430–1,478/s, with a maximum of 4,398/s.
   - Dead-task CPU is 60–67% of task CPU. The kernel takes 43% of task CPU, ~82% of it on the
     lifecycle of short-lived processes.
   - The mix shifts within a day. At night: statusline 52.5%, hooks 27.8%, worker-run 5%. In the
     evening: worker-run plus test suites. Storms track active worker runs (~60–75 extra births/s
     per run).
   - Long-lived bash sleep-poll loops add ≈ 2.1 cores, a lever separate from the spawn count.
2. **Felt slowdowns are Hammerspoon main-thread stalls**, ~5/h of 7–10 s, 2–3× more often in
   high-spawn hours.
   - The crash chain is stall → `hs` CLI abort → Hammerspoon SIGTRAP: 5 Hammerspoon crashes in
     4 days.
   - The suspects are 10 Hz AX polling (`claude_cmd_keys.lua`) and `hs -c` callers in tests. Both
     are our own code.
3. **Memory is compressed in a steady state, not in episodes.** The compressor held 3.5–6.3 GB,
   swap 4.5 of 6 GB.
   - Our fleet is ≈ 9.6 GiB. 5.9 GiB of it is ~100 idle bench Python workers, 74% of which is
     compressed or swapped. A gemini-web hidden browser peaked at 8.6 GB.
   - macOS has no pressure jetsam here. memlogd's guard is the only freeze protection. memlogd was
     redeployed on 2026-10-05, and the Harness doctor's DEPLOYS rows (shared-invariants `ef`) hold
     it.
4. **Disk: the internal SSD takes 182–405 GB of writes a day.**
   - ~76% of it is our own short-lived processes, ~17% kernel/APFS.
   - Swap is episodic: 0–43% of internal writes per window.
   - Git reads 1.31 TiB/day from the USB disk (logo-vectorizer-bench).
   - Free space was 80 GiB: uv cache 22 GiB, `~/.gemini-profiles` 17 GiB, a staged macOS update.
     SMART is healthy.
5. **There were 8 unclean reboots since 09-10**, including a 09-27 reboot loop. Shutdown stall 2 is
   ours: vendor-cli-update RunAtLoad left vendor-fingerprint still spawning at boot + 80 s.
6. **Retention of the sources:** the unified log ~11.5 h, launchd exit history ~11 h,
   DiagnosticReports ~7–8 days. Nothing older is recoverable, so the doctor keeps its own series.

## Phase 1 — built (`bin/system-doctor`, `share/machine_probe.py`)

Everything is unprivileged and bounded, and never runs inside memlogd's guard loop. The doctor
persists names, labels and counters only, never argv, paths or log bodies. Every probe binary and
source path is env-overridable (`SYSTEM_DOCTOR_<PROBE>`, `SYSTEM_DOCTOR_*_DIRS`, `SYSTEM_DOCTOR_DIR`).

- **LaunchAgent `com.llm-legs.system-doctor`.** Its program is the wrapper
  `~/.local/libexec/system-doctor`, written by `bin/system-doctor install-agent` and held by Harness
  DEPLOYS.
  - It runs `agent` every 60 s with ProcessType Standard, Nice 10 and LowPriorityIO. It never uses
    `taskpolicy -b`, which starved a research run for 40 min.
  - Each run is one tick, then the nightly pass when due, then the document every 10 min.
- **Tick** (~2.1 s wall, mostly the births window; ~0.1 cpu-s) writes `ticks/<day>.jsonl` and
  `tick-state.json`.
  - **Births/s:** the PID delta between two `ps` probes ~2 s apart, modulo 99,999.
  - **Births attribution:** newborns alive at the window's end, each charged to the nearest own
    script or own app above it.
  - **Tags.** An interpreter (`bash`, `python3`, `node`, …) is tagged by the script its argv runs: the
    first non-option argument (relative ones against the process's working directory), a `-m` module's
    file (else its name), and inline code (`-c`, `-e`, `-`) takes its parent's script through inline
    parents only. A script inside a repository beside ours is `repo/path` (through links; a worktree
    folds into its repository), any other its basename; no script readable keeps the interpreter's
    name. Each tick keeps the live interpreters it saw running a script in `tick-state.json` (`named`)
    and their deaths in `pids/<day>.jsonl` (pid, start, last seen, name), so a DiagnosticReports file of
    `Python` or `bash`, which carries only a PID, names the script that pid ran then. A launchd job
    whose program is an interpreter is named by its arguments' script the same way.
  - **Reaped-child CPU:** Δ`ps -S` minus Δ`ps` per `pid@lstart`, by the same tags.
  - **Kernel and busy shares** from host CPU ticks.
  - **Memory:** compressor size and share of RAM, swap use, page-in and swap-in rates, and swap-out
    bytes from `vm_stat` and `sysctl`.
  - **Disk:** per-device bytes read and written from `ioreg` (internal or external), and free space
    of Data and `/Volumes/*`.
- **Nightly**, after 04:00 or when older than 36 h, writes `nightly.json`:
  - DiagnosticReports headers (first 4 KB) by kind (crash, fault, hang, jetsam, panic, diskwrites,
    cpu_resource, wakeups, shutdownStall), process and owner, 8 days back;
  - relaunched launchd jobs (KeepAlive or StartInterval);
  - `last reboot shutdown` (an unclean boot is a boot whose previous record is a boot);
  - the biggest caches under ~ (`du`, 120 s budget, sizes only);
  - SMART via `diskutil info`.
- **Retention:** minute rows 14 days, hourly rollups (`hours/<day>.jsonl`) 90 days, daily rows
  (`days.jsonl`) forever.
- **Document** `~/.cache/system-doctor/latest.json`, in the shape of `docs/doctors-contract.md`.
  The ledger is `share/system-ledger.json`. The menu row is System, after Speed.

Problem rules (`LIMITS`; each names its top attributed cause where known; `fix_target` only when
the cause is our own):

| rule | fires at | heavy |
|---|---|---|
| `spawn` | hour mean ≥ 1,000 births/s, ≥ 3 ticks | ≥ 2,500 |
| `kernel` | hour mean sys share ≥ 0.40 | every tick of 30 min ≥ 0.55 |
| `compressor` | every tick of 10 min ≥ 33% of RAM | — |
| `swap` | latest tick ≥ 50% of swap allocated | — |
| `swap-writes` | 24 h swap-outs ≥ 20 GiB/day (≥ 1 h covered) | — |
| `ssd-writes` | 7-day mean > 200 GB/day (cause: top disk-writes report) | > 400 |
| `free-space` | a volume < 25 GiB free (Data's cause: the biggest cache, report-only) | < 10 |
| `hammerspoon-crash` | ≥ 1 crash in the day before the nightly pass | — |
| `job-crash` | ≥ 1 crash/day of a job launchd relaunches | — |
| `unclean-reboot` | ≥ 1 in 7 days (cause: a shutdown stall or panic within 1 h) | — |

## Phase 2 — built (2026-10-06)

- **Own causes only.** A cause is a fix target when its owner is `own` and it names a file of a sweep
  repository: its `repo/path` exactly, or a bare name by basename (`own_sources`: `git ls-files` of
  `~/.claude/sweep-repos`; Hammerspoon maps to `hammerspoon/init.lua`); `cause.files` lists them as
  `repo/path`. Everything else, a helper repository's `repo/path` included, reads
  `(<owner>, report only)` and never enters a fixer snapshot or a handoff.
- **Fixer routing.** `doctor-fix launch system [--night <id>]`, one area `system` (`whole`), so one run
  owns every cause of a night. The component is the cause's files; `what` names its levers (`LEVERS`,
  the list below). The night brief adds the rules: output-equivalent changes only, and speed never
  trades model, effort or thinking (close refuses a knob change, as for Harness).
- **Proof** (`PROOF`, in the judge digest). A fix is a ledger row matching `{rule, key, cause}`, status
  `fixed-pending`, with a `fixes[]` entry. Close runs `system-doctor check --record`: the row exists and
  a births/CPU cause has a baseline. The document then proves it once the fix's commit is in main
  (`fix_commit`, `fix_landed`):
  - `spawn`, `kernel`: the cause's attributed births/s and CPU cores after landing against the 7 days
    before. The window scales with the cause's cadence: 30 sightings at the baseline's rate (covered
    seconds ÷ ticks it was seen in), at least 2 h and at most 7 days, so a per-render script proves in
    2 h and a nightly one waits the week. Fewer than 30 sightings before is no baseline: refused.
    Proven when births or CPU fell ≥ 25 % and neither rose > 25 %.
  - crash, reboot and disk-writes rules: no report of the cause's kind since landing for 7 days;
    any report refuses it.
  - Proven reads `watch` (`proof.verdict`, counted `proved` by the night report) for 7 days; refused
    reads `open` with the numbers; pending reads `fixed-pending`. `system-doctor check <cause>` prints
    the same proof (exit 0 proven, 1 refused, 3 pending).
- **Harness overlap.** The machine rows are this doctor's alone: Harness's Load no longer judges
  forks, kernel, swap, CPU busy or unaccounted CPU (their `LIMITS` are gone); it judges the memory
  guard. Its samples stay for its Load rows, week table, day summaries and change impact.

## Phase 3 — built (2026-10-06)

The collectors run outside the minute tick. `agent` starts each one detached when due (`launched.json`), as
`system-doctor <collector> --quiet`, under its own lock, at Nice ≥ 10 with throttled disk I/O; each run is one
collector-runs row (`trigger background:<name>`) and keeps its own `self` wall/CPU. Names, labels and counters only.

- **Storm census** (`census`, `census/<day>.jsonl`). A storm is ≥ 2,000 births/s on every tick of the last 2 min, or
  the latest kernel share ≥ 0.5 (`tick-state.json` `recent`); at most one census per 30 min. It polls the process
  table through libproc every 20 ms for 60 s and charges each newborn it catches to the nearest own script or app
  above it, as the tick does. The judge merges the last hour's censuses into the `spawn`/`kernel` attribution, so a
  storm's short-lived parents name the cause.
- **Hourly `launchctl dumpstate`** (`dumpstate`, `launchd/<day>.jsonl`), parsed in memory (it carries env and argv).
  Per-service run deltas against `dumpstate-state.json` (a counter that fell is a reload: its runs since count; the
  first snapshot counts none), last exit as `exit N`/`signal N`, summed per label with unique parts (UUIDs, hex,
  long numbers) stripped; owner `own` (program under an own root), `apple`, `third-party`. Plus the orphan census:
  own-uid processes with ppid 1 that are no job and no own app, worker supervisors (open `worker-run` pids) apart.
- **6-hourly unified-log harvest** (`harvest`, `harvest/<day>.jsonl`). One `log show --style compact` per source from
  its cursor, at most 11 h back (`lost_s` counts what retention already dropped), each killed past its budget
  (launchd 300 s/100k lines, DAS 150 s/1.2M — it logs ~88k lines/h — hangs 60 s/20k); a cut source resumes after its last line. Kept: launchd
  exits per label (runs, wall, longest, abnormal exits, exit kinds), DAS starts/completions/decisions per activity,
  spindump spins and slow-HID per app.
- **Own footprints and disk counters** per tick (`proc_pid_rusage` v2 of our own live processes, ~2 ms):
  `mem_top` footprints, `io_top` bytes written/read and idle wakeups since the last tick.
- **Cohort score** (`cohort_sums` per day row, `cohort_score`): per item over the newest day rows covering ≥ 7 days
  (≤ 14 back), `B = max(C/864, W/86400, D/1 GiB, R/100 GiB, M/512 MiB × pressure, S/86400, L/1440)` per covered day;
  pressure = compressor ≥ 25 % of RAM or ≥ 2,000 swap-outs/s. Under 7 covered days nothing is scored. Apple and
  third-party items list W, D, R, M as unknown (`foreign-cohort-terms`).
- **Self-cost and blindness.** `costs` carries runs, wall and CPU per collector over 24 h; `collectors` names any blind
  one: `footprints` (own processes but no counters read), `dumpstate` (no snapshot for 3 h), `harvest` (none for
  12 h, or a source failed), `census` (its last run polled nothing).

New rules (fixer routing and proof as phase 2; an own cause with a sweep-repo file is a fix target, others report-only):

| rule | fires at | heavy |
|---|---|---|
| `job-loop` | a job launchd relaunches (KeepAlive or an interval) ≥ 60 runs/h and over twice its schedule, or ≥ 3 abnormal exits (non-zero exit, crash signal) a day from dumpstate or the log | ≥ 360/h or ≥ 24/day |
| `cohort` | B ≥ 1; non-own items read `watch`, never remove (at most 6 rows) | B ≥ 5 |

A `job-loop` fix is proven after 7 quiet days of snapshots; a looping snapshot since landing refuses it. A `cohort`
fix is proven on its births/CPU, so an item dominated by M, D, R or L is not measured by its proof yet.

Measured once on 2026-10-06 at ~350 births/s (real machine, temp state dirs):

| collector | wall | CPU | found |
|---|---|---|---|
| tick `rusage` step | 1 ms | ~0 | 34 of 35 own processes read; top footprints two bench workers ~770 MB each |
| census | 60 s | 1.5 s | 2,467 polls, 5,697 newborns (12 % gone before read); statusline.sh 38 % |
| dumpstate | 0.3 s | 0.2 s | 2,148 services; 1 own orphan |
| harvest, 11 h back | 88 s | 76 s | launchd 80 s/72 cpu-s of it (`log show` predicate scan); DAS 562k lines 12 s/10 cpu-s; Siri.agent 4 × `exit 1` (Apple, report-only), Hammerspoon 5 spins |

A 6-hourly run reads 6 h, about half the first run's cost.

## Log stores — built (2026-10-09)

Egor must see how much disk LLM logs take and whether they grow, even when a writer nobody registered logs somewhere
new. Writers stay free: no format or location standard, we only measure and clean.

- **Registry** `share/log-stores.json` (`share/log_stores.py`): one entry per store, `globs` (one match = one unit; a
  directory ages by the newest mtime inside it), `writer`, `owner`, `cleaner` (`self` the writer prunes, `sweep`
  `bin/log-sweep`, `cap` the app caps, `keep` measured only) and at most one criterion (`days`, `max_mb`,
  `keep_newest`, `tail_mb`; `self` and `sweep` need one), each with its `why`. `kind` is `log` (a tool writes it on
  its own and it accumulates: the only kind the doctor counts) or `app` (app data, binaries, browser profiles,
  outputs: listed so the fallback skips it, never measured). A log store lists its `readers`, found by grepping our
  repos, or `[]`. Logs token-map reads keep 30 days (it shows 4 weeks); session scratch and top-level tmp sandboxes
  (`"type": "dir"`, own directories only) 7 days idle; unread logs the shortest that still serves debugging.
  `ignore` lists what is clearly not an LLM log, each with a reason; nothing is ignored silently.
- **Collector** `logstores`, daily after 04:00 (or after 36 h), detached like the others: `bin/log-sweep` (every
  `sweep` store, any kind), then every log store's bytes, files, units and oldest unit, and what lies past its
  criterion plus slack (2 days, 1 unit, 25 %, 2× the tail). Rows in `logstores/<day>.jsonl` (90 days).
- **Fallback** for unregistered writers: one `du -k -x` per top scan root, deep enough to reach 3 levels below every
  root inside it. A directory 1–3 levels below its root that no store unit or ignore entry covers is judged on its
  residual (its size minus covered, nested-root and already-reported parts below it): reported at 200 MB, or at
  50 MB/day of residual growth against the newest scan 20 h–8 days old (`logscan/<day>.json`, 14 days). Measured
  2026-10-09 at load ~100: du 166 s wall (64 cpu-s) over 163k directories, stores 31 s, sweep 18 s; budget 600 s,
  a cut du reads blind.

| rule | fires at | heavy |
|---|---|---|
| `log-store` | a store holds units past its criterion plus slack, or log-sweep failed (cause: log-sweep, or the `self` writer) | — |
| `log-growth` | the total of all stores grew ≥ 1 GiB/day over ≥ 5 days of the newest 7 and grew in the last day | ≥ 3 GiB/day |
| `unregistered-store` | a directory the fallback names (key: its path), report-only | — |
| `log-unread` | a log store with `readers: []` holding bytes: written, read by nobody (no cause; the fix is a reader or less writing) | — |

`log-growth` threshold: with every big store under a criterion the total plateaus; 1 GiB/day sits under the biggest
single inflow measured (tmp session scratch, ~1.3 GB/day) and above a retention-limited store's daily swing; re-tune
once 14 days of series exist. A `log-store` fix is proven when the next scan no longer fires it.

## Left

- **Felt score** for scheduling levers (stalls, slow HID) — the hang and DAS counters feed no rule yet.
- **Cohort proof** on its own dominant term (M, D, R, L) instead of births/CPU.
- **Retention of `collector-runs.jsonl`:** 30 days.
- Short-lived and other users' disk I/O and footprints stay blind without a consented privileged sample
  (ledger `ssd-writers`, `foreign-cohort-terms`).

## Levers (own code, output-equivalent; every one needs a before/after on this collector)

1. **Spawn rate.**
   - Statusline first: cache git and jq per render keyed on mtime, take review-flow-gate off the
     render path, add a births-per-render metric.
   - No-fork bash idioms and ≥ 1 s waits in worker-run, worker-pick and llm-limits.sh.
2. **Hammerspoon.** Make no `hs -c` calls from scripts or tests. Make AX polling event-driven or
   ≤ 1 Hz. Free the leaked drawings.
3. **gemini-web hidden browser:** close it on idle.
4. **harness-doctor's own cost**, which grew 657 → 1,565 cpu-s/day.
5. **Homebrew bash teardown segfault** (49 in 8 days): find the children that die after their parent.
6. **vendor-cli-update RunAtLoad:** drop it, or add a boot delay (shutdown stall 2).

Egor's trades: a consented privileged sample, the night-run window, bench pool size, Spotlight
exclusions, disk housekeeping (uv cache, gemini profiles, the staged macOS update) and idle apps.
