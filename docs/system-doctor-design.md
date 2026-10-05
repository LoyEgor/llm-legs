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
    script (by basename) or own app above it.
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
  The ledger is `share/system-ledger.json`. The menu row is System, after Speed. Fix shows
  "report only".

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

## Phase 2 — left

- **Fixer routing.** `doctor-fix launch system` refuses until then. Phase 2 adds the launch path,
  the night prose (`docs/night-run.md`) and a `docs/doctor-fix.md` section. One cause, one fixer
  owner.
- **Harness overlap.** Harness's Load section already judges forks (red 2,500), kernel (red 0.5)
  and swap share (red 0.9). Phase 2 decides which doctor owns those rows.
- **Collectors not built:**
  - the newborn census on a storm (≥ 2,000/s for 2 min or sys ≥ 0.5, one 60 s census at most every
    30 min);
  - the hourly `launchctl dumpstate` run counters and orphan census;
  - the 6-hourly unified-log harvest (launchd exits, DAS verdicts, hangs);
  - own-process footprints and disk counters (`ledger blind_spots`).
- **Cohort score** per item i, amortized over ≥ 7 days:
  `B_i = max(C/864, W/86400, D/1 GiB, R/100 GiB, M/512 MiB × pressure, S/86400, L/1440)`.
  B ≥ 1 is review, ≥ 5 heavy. A separate felt score decides scheduling levers only. Unknown value
  → watch, never remove.
- **Retention of `collector-runs.jsonl`:** 30 days.

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
