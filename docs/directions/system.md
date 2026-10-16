# System (direction 3)

The machine: our own background processes (statusline, Hammerspoon, samplers, collectors, daemons), disk writes,
swap and stores. Only our own processes are worked; Apple and third-party ones are watched (Decisions). The System
doctor's own UX belongs to the owner chat «Передача system-doctor-ux», never a goal here.

## Metric

- Own background CPU-min/day: our processes run with no order behind them, and our hooks (README). Test CPU is Lost
  time's; the work (worker-run, image-fanout, agy, night-run, doctor-fix, review-bench, the logo bench) is load.
- Beside it, never folded in: CPU ms a render and a hook run, renders and hook runs a day, present hours a day; SSD
  GB and swap GiB written a day. The total follows open chats and tool calls (renders 109k–220k a full day,
  10-06…15), so a goal is proven on its own number and this one is read 7 days after.

### Baseline (computed 2026-10-16)

Per covered day (`covered_s`). 10-06 is out: the System doctor covered 0.73 of it, the render cuts landed in it.

| per covered day | 10-07…08 (2.0 d) | 10-09…15 (6.31 d) |
|---|---:|---:|
| **own background CPU-min/day** | **911** | **862** |
| statusline renders | 289 | 231 |
| statusline probes and merge kicks | 271 | 238 |
| hooks | 174 | 166 |
| Hammerspoon | 105 | 95 |
| doctors (collector runs) and the System doctor's ticks | 62 | 103 |
| memlogd | 0 | 17 |
| token-map scan | 10 | 12 |
| ssd-sampler, llm-refresh, llm-selfcheck, vendor-cli-update | 0 | 0.5 |
| CPU ms a render (renders a day) | 94.9 (183k) | 87.6 (158k) |
| CPU ms a hook run (runs a day) | 36.9 (283k) | 28.6 (348k) |
| present hours a day | 12.6 | 13.8 |
| **SSD written, GB/day** | **313** | **441** |
| **swap written, GiB/day** | **4.8** | **88.5** |

The 10-13/14 cuts moved the level: 10-15 alone is 612 (renders 128, probes and kicks 75, hooks 148, Hammerspoon
100, doctors 96, memlogd 59).

Method, `python3 -I`, local days, each sum ÷ 60 ÷ (Σ `covered_s` / 86400):
- Renders and hooks: `~/.cache/harness-doctor/speed-days/<day>.json` `statusline` (`cpu_ms`, `renders`) and
  `hook_cpu_us_total` ([runs, CPU µs], `stop.d/` inside `stop-dispatch.sh`), kept 28 days (raw journals 3).
- Probes and kicks: Σ column 3 (CPU ms) of `~/.cache/speed-doctor/statusline-probes/<day>.tsv` (column 5 = 1:
  output unchanged) and of `merge-kick/<day>.tsv`, by the local day of column 1.
- Doctors: Σ `cpu_s` of `~/.cache/doctors/collector-runs.jsonl` by the local day of `start`, plus `tick_cpu_s`.
- Processes: `~/.cache/system-doctor/days.jsonl` `cpu_own` field 2 (every own tag, since 10-13), `cohort` field 3
  before, tags ending in Hammerspoon, memlogd, `tokenmap/__main__.py`, ssd-sampler, llm-refresh, llm-selfcheck or
  vendor-cli-update. `cohort` keeps a day's top 100 of each tick's top list (memlogd 32/43 there, 47/59 in
  `cpu_own` on 10-14/15). From 10-14 (7fcf0fc1) a tag carries its dead children's CPU: Hammerspoon's is 55–64 %
  children and memlogd's 97 % against 1–3 % on 10-13, so those lines count different things across that commit.
- SSD and swap: Σ `ssd_w_b` ÷ 1e9 and Σ `swapout_b` ÷ 2^30. Present: minutes idle < 600 s in
  `~/.cache/speed-doctor/presence/<day>.tsv` (minute, idle seconds, front app).

## Sources

- The Method's journals; `~/.cache/harness-doctor/statusline/<day>.tsv` (a render: start µs, end µs, session, CPU
  ms, same 1/0/`a` away); `~/.cache/system-doctor/ticks/`, `hours/` and `latest.json` (`background`,
  `measures.ssd_sampled`, `nightly` crashes); `~/.hammerspoon/llm_limits_actions.log`.
- Ledgers: `share/system-ledger.json`, the `cpu:` rows of `share/spend-ledger.json` (`share/cpu_audit.py`, live in
  `~/.cache/harness-doctor/latest.json` `speed`), the Speed rows of `share/harness-ledger.json`.

## Recurring classes

Ranked 2026-10-16 by CPU from the ledgers above and git history (llm-legs, hammerspoon, token-map, claude-setup);
the log audit's 105 rows hold none that moves CPU or disk.

| class | CPU-min/day 10-09…15 | rows | days fixed | instances fixed |
|---|---:|---:|---:|---:|
| 1. the statusline recomputes what did not change | 468 | 8 | 3 (10-06, 10-13, 10-14) | 10 |
| 2. a hook starts a bash per tool call | 166 | 50 | 2 (10-13, 10-14) | 35 |
| 3. a doctor run costs more each day it holds more data | 103 | 3 | 1 (10-14) | 2 |
| 4. a Hammerspoon timer polls on the main thread | 95 | 3 | 4 (10-09, 10-10, 10-13, 10-14) | 8 |
| 5. a CPU audit reopens on a number not its own | audits' churn | 28 due | 0 | 0 |
| 6. a store rewritten whole instead of its delta | SSD | 3 | 2 (10-13, 10-14) | 2 |

CPU-min/day is the Baseline's 10-09…15 lines (class 1 = renders + probes and kicks). Rows: the ledger ids each
item names (class 2: the 50 `cpu:hook/*`; class 6: system-ledger `token-map-scan-writes`, `-cohort`,
`review-anchors-blob-memo-rewrites`). Days and instances fixed: distinct fixing commits or `cut` verdicts by date
(`fixes[].at`, `audited_at`); one commit credited to two rows is one instance (token-map 825b88f).

1. Rows `cpu:statusline/{render,ports,unpushed,work,debt,autonomy}`, `cohort-statusline-renders`,
   `statusline-render-load`; each audit caches one section, a new one joins uncached. 10-15: 117 CPU ms a changed
   render (28k), 72 an unchanged one (52k), 22 an away replay (29k); work and ports probes 93 % and 99.8 % unchanged.
   Its forks were the spawn storm (`births_s` 920/s on 10-13, 135 on 10-15; `docs/system-doctor-design.md`). No
   goal: a whole-render memo needs an exact key (payload, every cache and store, the tree's `git status`, the second
   a work line ticks), must still kick the probes (`bin/statusline.sh:2271`), saves ≤ 30 CPU-min/day (a hit still
   pays ≈ 40 of 72 ms) and freezes a segment on a missed input. The CPU audits keep cutting sections.
2. Rows `cpu:hook/*`. CPU a run fell 36.9 → 28.6 ms; runs follow tool calls. No goal: the dispatcher was declined
   (2026-10-05, `spend.md`) and no new hooks, so the CPU audits cut them one by one, dearest first.
3. Rows `cpu:doctor/{speed,system,harness}`. Median CPU s a run (`collector-runs.jsonl` `cpu_s` by the local day of
   `start`; 10-16 to 22:00) 10-13/14/15/16: Speed 7.5,
   11.1, 12.6, 15.2; System 1.0, 2.4, 3.6, 5.0; Harness 24.6, 8.3, 5.9, 7.1. No commit to either rising doctor
   after 10-14 (`share/time_budget.py` once on 10-15): the rise is their data.
4. Rows `cohort-hammerspoon-tab-poll`, `cpu:process/Hammerspoon`, `speed-hs-lag-instruction-watch-walk` (iPad
   pointer trace, instruction-watch walk ×2, tab poll ×3, menu rebuild ×2). 14 files start repeating timers, each
   with its own idle rule; three gate on `Presence.away()`. Present minutes carry 93, 84, 55 CPU-min on 10-14/15/16,
   away ones 11–16 (goal tab-tty's join), so an away-timer helper was dropped. A Terminal-front present minute
   costs 8.38 CPU-s, any other app's 3.24 (10-14…16, 1,245 and 1,079 min): the Cmd-key tab poll runs a ps every
   0.45 s idle tick and re-reads the tab's tty by osascript every `ttyRefreshAfter` 1 s (`refreshTty`, 44 a quiet
   minute in 75d60db), 50–60 ms CPU each in osascript alone (timed here). Next, unconfirmed: `llm-limits.lua`
   `onStoreChanged` → `refreshRouting` runs `nice worker-pick --menu` per store write (2 s throttle), 1,383–1,994
   a day 10-14…16 (`routing-launch` lines in the actions log, 10-16 to 22:20), 0.44–0.93 CPU-s each (diagnosis); whether the writes change its input is open.
5. `share/cpu_audit.py` `due()` reopens a row on another source blob (`spend.moved`) or on CPU-min/day 1.5× the
   audit's, neither the component's own cost (Lost time's 2026-10-16 decision makes these System's). On 10-16 21:46
   33 were due: 2 never audited, 14 source changed, 17 rises, mostly runs (hooks 5,712 → 13,049 a day at 0.007 s).
   Only 3 ran slower: `hook/review-owner-gate.sh` ×5.6, `doctor/speed` ×1.7, `run-suites.sh` ×16 (test load).
   `cpu:hook/context-nudge.sh` was re-audited on 10-14 when an edit "moved the source; the cost did not".
6. Since 10-15 no own writer the ticks see passes 1 GB/day but the load (agy, the logo bench) and
   transcriptions-gpt (accepted): memlogd 0.84 on 10-15 (`days.jsonl` `cohort` field 5); 10-14 had review-bench 2.93
   before its 08:19 fix. One dying between ticks
   takes its write counters along (blind spot `ssd-writers`: the 10-04 privileged trace put ≈ 76 % of writes on our
   own short-lived processes). The root ssd-sampler's first 20 v3 samples (`/var/db/ssd-sampler`, 10-13 22:12 …
   10-16 17:06, 22 min, shares as `system-doctor` `ssd_sampled()`): kernel_task 55 % (swap 28 %),
   the logo bench's `$TMPDIR` ≥ 17.5 %. No goal until its 7-day shares name an own writer.

## Goals

After Breakages' and Lost time's goals (PILOT order). `cpu-audit-own-number` goes first: goal 2's doctor edits
would otherwise reopen the `cpu:doctor/*` rows. `doctor-run-flat` recovers ≈ 36 CPU-min/day and grows daily (Speed
195 runs × 7.7 s, System 171 × 4 s over 10-13's; runs a calendar day 10-09…15), `tab-tty` ≈ 25 ((5.14 − 1.5) CPU-s × 415 Terminal-front minutes a
day). Classes 1, 2 and 6 have no goal (above).

### goal cpu-audit-own-number: a CPU audit comes due only on its own slower run

Class 5.
- llm-legs `share/cpu_audit.py` `due()`: the `spend.moved` reason and `collect()`'s blob hashing go; due = never
  audited or `cpu_s_run` ≥ `spend.SHARE_RISE` × the row's. Spend keeps its `spend.moved` caller; Lost time's
  `audit-own-number` makes the same change in `suite_audit`.
- Proof: old and new `due()` over one copy of the CPU journals, `spend-ledger.json` and HEAD. Before (10-16 21:46):
  33 due, 28 with no per-run rise; target 0 of those 28. After landing, 7 daily reads of the Speed doctor's
  `cpu_audit` problems: none due without a per-run rise.
- Must not get worse: every per-run rise ≥ 1.5× is due (3 of 3 in the replay); the Speed doctor's CPU a run.

### goal doctor-run-flat: a doctor run reads what is new since its last

Class 3.
- llm-legs `bin/speed-doctor` and `bin/system-doctor`: `python3 -m cProfile` on a state copy (`SPEED_DOCTOR_DIR`,
  `SYSTEM_DOCTOR_DIR`, `HARNESS_DOCTOR_DIR`, `DOCTORS_DIR`; `CLAUDEB_DIR` a fixture) names the reads whose cost
  follows the days held; each moves to an existing reader (Speed's `read_new` + `fold_jsonl`, `cpu_audit.tally`'s
  size+mtime cache) and the one it replaces goes.
- Proof: a state copy 5 min after a live run, old and new alternated on fresh copies, 5 pairs a doctor, CPU s a run
  from the copy's `collector-runs.jsonl`. Before (10-16 medians to 22:00): Speed 15.2, System 5.0; after landing the daily
  medians stay flat 7 days (they rose 1.2–2.6 s a day from 10-14).
- Must not get worse: `latest.json` equal old vs new on one copy, clock pinned (`SPEED_DOCTOR_NOW`; System's
  timestamps aside).

### goal tab-tty: Hammerspoon reads a tab's tty once a tab, never on a timer

Class 4. A tab keeps its tty for its life.
- hammerspoon `claude_cmd_keys.lua`: `refreshTty` runs when the observed tab changes (window id, tab index or tab
  element, `sameObserved`) or the context is invalidated; the `ttyRefreshAfter` recheck in `pollFrontTab` goes. The
  ps verdict keeps its poll.
- Proof: extra Hammerspoon CPU of a Terminal-front present minute over another app's (`ticks/<day>.jsonl`
  `cpu_own` Hammerspoon field 2 by the minute of `t`, joined to that or the minute before in `presence/<day>.tsv`,
  idle < 600 s, front app column 3): 5.14 CPU-s (10-14…16) → ≤ 1.5 over 7 days after landing. osascript a quiet
  minute in 75d60db's simulator (`tests/claude_cmd_keys_harness.lua` `env.idle.run`): 44 → 0, old vs new.
- Must not get worse: a tab switch re-reads the tty before a press acts (a harness case red on a never-re-read
  version); 75d60db's first-press and `cacheTtl` cases; away-minute Hammerspoon CPU.

## Done

| date | change | result | evidence |
|---|---|---|---|
| 10-06 | statusline render cuts | ≈230 → 120 ms CPU a render; interval stays 3 s | `docs/handoffs/2026-10-05-hook-cuts-left.md` |
| 10-13 | ssd-sampler v3 as a system service (per-process writes, CPU, memory); Background grouped by project | | |
| 10-13 | token-map writes only what changed | writes 1.3 GB/h → 3.5 MB/h | token-map 825b88f |
| 10-13/14 | six statusline sections cut by CPU audit | renders 286 → 128, probes 394 → 65 CPU-min/day (10-13 → 10-15) | `cpu:statusline/*` |
| 10-14 | Hammerspoon tab poll idle-adaptive | 105, 100 CPU-min/day on 10-14/15 with children, not proven | hammerspoon b4a4941, 75d60db |
| 10-14 | the System doctor's blind spot | | 7fcf0fc1 |

## Decisions

- 2026-10-14: Away Mode (10 idle minutes or his click, ☾ before Auto): what only informs him slows or stops while
  he is away (Gemini quota ≥ 1 h, the statusline replays its last line, the Cmd-key tab poll and Auto-menu rebuilds
  stand still); Claude limits polling never slows. Every away gate reads `Presence.away()`, so the one switch
  detaches them all; he may drop the mode, so it stays simple. («Передача system-doctor-ux»)
- 2026-10-14: the statusline refresh stays 3 s; only the per-render cost is cut. («Передача system-doctor-ux»)
- 2026-10-14: no phantom rebuilds: a menu nobody opens is not rebuilt on a timer, but only where the gain is worth
  it and nothing fragile. («Передача system-doctor-ux»)
- 2026-10-14: measure everything, cheaply: the knowing must not slow the Mac (one machine-wide sampler, bash
  builtins); our doctors' and collectors' own cost is counted and checked like any own process.
  («Передача system-doctor-ux»)
- 2026-10-14: other projects' background programs are shown by harm in Background, never worked or proposed for
  removal: he removes the harmful ones himself. transcriptions-gpt's overlay CPU and daemon writes are accepted,
  never a goal. («Передача system-doctor-ux»)
- 2026-10-13: Apple/macOS causes are detected and shown red, reported only. («Передача system-doctor-ux»)
- 2026-10-13: obvious LLM garbage (off-menu profiles, idle unknown LLM dirs) is cleaned unasked by the night's
  `system-doctor tidy`, to the Trash only; any other disk cleanup is his. Retention: his chats 180 days, worker
  transcripts 15, Gemini listen audio 2 (`share/log-stores.json`). («Передача system-doctor-ux»)
- 2026-10-06: caches are measured, never cleaned by the night; Spotlight is dropped; the bench pool is his, and
  other chats' load is weather, never paused (2026-10-05). («Updater doctor»)

## Open

- Swap since 10-12 (46, 30, 398, 79 GiB on 10-12…15): footprint under pressure 10-09…15 is 48 % own (bench pipelines,
  Hammerspoon 3.8 %), claude 11 %, Blender 11 % (`cohort` 8th field). Owner chat.
- memlogd 0.7 → 47–59 CPU-min/day from 10-14: 7fcf0fc1 made its forks visible (Method); whether chat-load's
  footprint reads (435f5b3f, adf10968) added cost is not settled.
- `hs-cli-dead-port` is Breakages' (a crash moves no System number; its Sources do not read the System doctor yet).
  The chain is open (system-ledger): production callers run `hs` unlocked with the default 4 s `-t`
  (`bin/claude-chat-switch:512`, `claude-resume-timer:384`, `llm-selfcheck:59`, …). Back once after the 10-09 fix
  (10-14 03:40), not since the 10-14 08:19 one; the 10-14 15:45 crash is another bug (`luaT_gettmbyobj` assert).
- `cohort`'s cuts undercount small own rows (Method), and `worker-run`'s CPU check is pending: the owner chat's.
