# System (direction 3)

The machine: our own background processes (statusline, Hammerspoon, samplers, collectors, daemons), disk writes,
swap and stores. Only our own processes are worked; Apple and third-party ones are watched (Decisions). The System
doctor's own UX belongs to its owner chat (Decisions), never a goal here.

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
| doctors and the System doctor's ticks | 62 | 103 |
| memlogd | 0 | 17 |
| token-map scan | 10 | 12 |
| ssd-sampler, llm-refresh, llm-selfcheck, vendor-cli-update | 0 | 0.5 |
| CPU ms a render (renders a day) | 94.9 (183k) | 87.6 (158k) |
| CPU ms a hook run (runs a day) | 36.9 (283k) | 28.6 (348k) |
| present hours a day | 12.6 | 13.8 |
| **SSD written, GB/day** | **313** | **441** |
| **swap written, GiB/day** | **4.8** | **88.5** |

The 10-13/14 cuts moved the level: 10-15 alone is 612; 10-16…22 average 475 (renders 126, probes and kicks 68,
hooks 89, Hammerspoon 68, doctors 79, memlogd 33).

Method, `python3 -I`, local days, each sum ÷ 60 ÷ (Σ `covered_s` / 86400):
- Renders and hooks: `~/.cache/harness-doctor/speed-days/<day>.json` `statusline` (`cpu_ms`, `renders`) and
  `hook_cpu_us_total` ([runs, CPU µs], `stop.d/` inside `stop-dispatch.sh`), kept 28 days (raw journals 3).
- Probes and kicks: Σ column 3 (CPU ms) of `~/.cache/speed-doctor/statusline-probes/<day>.tsv` (column 5 = 1:
  output unchanged) and of `merge-kick/<day>.tsv`, by the local day of column 1.
- Doctors: Σ `cpu_s` of `~/.cache/doctors/collector-runs.jsonl` by the local day of `start`, plus `tick_cpu_s`.
- Processes: `~/.cache/system-doctor/days.jsonl` `cpu_own` field 2 (every own tag, since 10-13), `cohort` field 3
  before, tags ending in Hammerspoon, memlogd, `tokenmap/__main__.py`, ssd-sampler, llm-refresh, llm-selfcheck or
  vendor-cli-update. `cohort` keeps a day's top 100 of each tick's top list. From 10-14 (7fcf0fc1) a tag carries
  its dead children's CPU (Hammerspoon 55–64 %, memlogd 97 %; 1–3 % on 10-13), so those lines count different
  things across that commit.
- SSD and swap: Σ `ssd_w_b` ÷ 1e9 and Σ `swapout_b` ÷ 2^30. Present: minutes idle < 600 s in
  `~/.cache/speed-doctor/presence/<day>.tsv` (minute, idle seconds, front app).

## Sources

- The Method's journals; `~/.cache/harness-doctor/statusline/<day>.tsv` (a render: start µs, end µs, session, CPU
  ms, same 1/0/`a` away); `~/.cache/system-doctor/ticks/`, `hours/` and `latest.json` (`background`,
  `measures.ssd_sampled`, `nightly` crashes); `~/.hammerspoon/llm_limits_actions.log`.
- Ledgers: `share/system-ledger.json`, the `cpu:` rows of `share/spend-ledger.json` (`share/cpu_audit.py`, live in
  `~/.cache/harness-doctor/latest.json` `speed`), the Speed rows of `share/harness-ledger.json`.

## Recurring classes

Ranked 2026-10-16 by CPU from the ledgers and git history; the log audit's 105 rows move no CPU or disk.

| class | CPU-min/day 10-09…15 | rows | days fixed | instances fixed |
|---|---:|---:|---:|---:|
| 1. the statusline recomputes what did not change | 468 | 8 | 3 (10-06, 10-13, 10-14) | 10 |
| 2. a hook starts a bash per tool call | 166 | 50 | 2 (10-13, 10-14) | 35 |
| 3. a doctor run re-reads what did not change | 103 | 3 | 2 (10-14, 10-23) | 3 |
| 4. a Hammerspoon timer polls on the main thread | 95 | 3 | 5 (10-09, 10-10, 10-13, 10-14, 10-23) | 9 |
| 5. a CPU audit reopens on a number not its own | audits' churn | 28 due | 1 (10-23) | 1 |
| 6. a store rewritten whole instead of its delta | SSD | 3 | 2 (10-13, 10-14) | 2 |

CPU-min/day: the Baseline's 10-09…15 lines (class 1 = renders + probes and kicks). Rows: the ledger ids each item
names (class 6: system-ledger `token-map-scan-writes`, `-cohort`, `review-anchors-blob-memo-rewrites`). Days and
instances fixed: distinct fixing commits or `cut` verdicts by date; one commit on two rows is one instance.

1. Rows `cpu:statusline/{render,ports,unpushed,work,debt,autonomy}`, `cohort-statusline-renders`,
   `statusline-render-load`. 10-22: 109 CPU ms a changed render (23k), 89 an unchanged one (65k), 21 an away
   replay (58k); 4 chats rendered ≈ 29k times each. No goal: a whole-render memo needs an exact key (payload, caches,
   stores, `git status`, the ticking work line), saves ≤ 30 CPU-min/day (a hit pays ≈ 40 of 72 ms) and freezes a
   segment on a missed input; the CPU audits cut sections.
2. Rows `cpu:hook/*`. CPU a run fell 36.9 → 28.6 ms; runs follow tool calls. No goal: the dispatcher was declined
   (2026-10-05) and no new hooks; the CPU audits cut them dearest first.
3. Rows `cpu:doctor/{speed,system,harness}`; the 10-13…16 rise was load. Median CPU s a run, 7 days → 10-23 after
   doctor-run-flat (53 runs): Speed 7.75 → 2.51, Harness 3.28 → 2.73, System agent 3.79 → 1.08; 65 % of runs come
   while he is away (goal doctors-away). Left: run-suites' unpruned `runs.jsonl`, parsed whole by Speed (≈ 0.25 s).
4. Rows `cohort-hammerspoon-tab-poll`, `cpu:process/Hammerspoon`, `speed-hs-lag-instruction-watch-walk`. 14 files
   start repeating timers; three gate on `Presence.away()`. The join: `ticks/<day>.jsonl` `cpu_own` Hammerspoon
   field 2 by the minute of `t`, joined to that or the minute before in `presence/<day>.tsv` (idle < 600 s, front
   app column 3). Away minutes carried 11–16 CPU-min a day, present ones 55–93 (10-14…16), so no away-timer
   helper; the tab poll's ps every 0.45 s is left. Of its 45 child CPU-min/day (10-16…22), `refreshRouting`'s
   `worker-pick --menu` is 17–23 (1,159 runs a day), half on an unchanged store (goal routing-once).
5. `share/cpu_audit.py` `due()` rose on CPU-min/day, which follows runs, since 10-23 on CPU a run; so a cut row
   never reopens on its total (`cpu:statusline/work`: 36.8 CPU-min/day 10-16…22, 95 % unchanged).
6. Since 10-15 no own writer the ticks see passes 1 GB/day but the load (agy, the logo bench) and
   transcriptions-gpt (accepted) (`days.jsonl` `cohort` field 5). One dying between ticks
   takes its write counters along (blind spot `ssd-writers`: the 10-04 trace put ≈ 76 % of writes on our own
   short-lived processes). ssd-sampler (`ssd_sampled()`, 48 samples to 10-23): kernel_task 19 %, `$TMPDIR`
   (Blender, the logo bench) 32 %, `~/.cache/harness-doctor` 4 %; no goal until it names an own writer.

## Goals

By CPU-min/day (deep search 10-23): doctors-away ≈ 14, routing-once 10–16; each after its class's 10-30 read
(doctor-run-flat, tab-tty), which it would skew. Classes 1, 2 and 6 have none.

### goal doctors-away: a background doctor run while he is away comes 30 min after the last

Class 3. 164 of 251 Harness runs a day (each execs Speed) start while he is away (10-16…22, `collector-runs.jsonl`
by `presence/<day>.tsv` idle ≥ 600 s, as are 65 % of minutes); nobody reads the menu then, and the night's prep
runs `harness-doctor` itself.
- First step: whatever a Harness or Speed run samples live, not from a journal, keeps its cadence, or the goal stops.
- Change: llm-legs `launchd/harness-doctor` (launchd, 300 s) exits before python while `share/presence.sh`
  `presence_away` holds and `latest.json` is under 30 min old; a direct call is never gated.
- Proof, a replay: 10-16…22's away runs thinned to one per 30 min keep 114 of 251 a day, skipping 29.7
  CPU-min/day at recorded CPU, 14.3 at 10-23's medians. Landed, 7 days: away runs ≤ 30 a day, their CPU ≤ 3.5
  (≈ 17) CPU-min/day.
- Must not get worse: a night's `doctor_problems_after` reads a run newer than its last job (no gate while a night
  is open); present runs 5 min apart; a closed day's `budget-days` units.

### goal routing-once: one store write runs worker-pick --menu once

Class 4. A 3-min watch on 10-23: 3 store writes (a new inode each), 6 `routing-launch` lines, each second one 2–5 s
later on the same inode, mtime and size (the 2 s throttle's trailing timer). 10-19…22: 3,158 of 5,462 launches
within 5 s of the one before; 126 a present hour. A run: 0.83–0.95 CPU-s on a fixture store, 1.2 by class 4's
join (reaped CPU-s a present tick, 2 launches vs 0: 5.21 vs 2.83).
- First step: the writer's `~/.llm-limits.json.tmp.XXXXXX` shares the store's path prefix; reproduce both
  launches in `tests/llm_limits_renderer_harness.lua` and whether the first reads the old store.
- Change: llm-legs `hammerspoon/llm-limits.lua` `onStoreChanged` launches only when the store's `ino`, `size` or
  `modification` (`hs.fs.attributes`) moved since the last launch; an unchanged store arms no timer.
- Proof: harness, one write's two callbacks 2 → 1 launch. Live, 7 days: launches within 5 s 58 % → ≤ 5 %, a
  present hour 126 → ≤ 65.
- Must not get worse: a new inode in the same second launches (a case red on an mtime-only key); the submenu's dim
  rule; class 4's join.

Checked 10-23, not goals: an away-replay early exit (13.7–16.3 → 8.6–10.9 ms CPU on a fixture, ≈ 5 CPU-min/day);
bash 5's start (7.3 ms CPU vs `/bin/bash`'s 2.5, CoreFoundation via libintl, ≈ 350k own runs a day: a custom
build); the `env bash` hop (noise); a hidden-tab replay (a second freeze: his trade); a work-probe memo (class 1);
`worker-pick`'s catalog reads (0.43 CPU-s a run); System's away judge runs (1.7 CPU-min/day).

## Done

| date | change | result | evidence |
|---|---|---|---|
| 10-06 | statusline render cuts | ≈230 → 120 ms CPU a render; interval stays 3 s | `docs/handoffs/2026-10-05-hook-cuts-left.md` |
| 10-13 | ssd-sampler v3 as a system service; Background grouped by project | | |
| 10-13 | token-map writes only what changed | writes 1.3 GB/h → 3.5 MB/h | token-map 825b88f |
| 10-13/14 | six statusline sections cut by CPU audit | renders 286 → 128, probes 394 → 65 CPU-min/day (10-13 → 10-15) | `cpu:statusline/*` |
| 10-14 | Hammerspoon tab poll idle-adaptive | 105, 100 CPU-min/day on 10-14/15 with children, not proven | hammerspoon b4a4941, 75d60db |
| 10-14 | the System doctor's blind spot | | 7fcf0fc1 |
| 10-23 | goal cpu-audit-own-number: audits rise on CPU a run | replay: rise-due 3 (×0.2–1.05 a run) → 3 (×1.6–3.5, missed before), per-run ≥ 1.5× due 3/6 → 6/6; read 10-30: no rise-due without a per-run one | 627bc40d |
| 10-23 | goal tab-tty: a tab's tty read on a tab change, never a timer | quiet Terminal-front minute: osascript 44 → 0, AX walks 310 → 266; read 10-30 by class 4's join: extra CPU-s a Terminal-front minute 5.16 → ≈ 2.7, away ≤ 1.67 | hammerspoon d3bb5a6 |
| 10-23 | goal doctor-run-flat: a doctor run reads only what changed (git per HEAD, day files by size+mtime) | 5 warmed pairs, CPU s a run: Speed 4.2 → 1.5, System judge 1.7 → 0.6, Harness 2.7 → 2.3, code 2.5 → 2.0; `latest.json` equal; read 10-30: medians within 10-17…23's | 9392991b |

## Decisions

From «Передача system-doctor-ux» unless named.

- 2026-10-14: Away Mode (10 idle minutes or his click, ☾ before Auto): what only informs him slows or stops while
  he is away (Gemini quota ≥ 1 h, the statusline replays its last line, the Cmd-key tab poll and Auto-menu rebuilds
  stand still); Claude limits polling never slows. Every away gate reads `Presence.away()`, so the one switch
  detaches them all; he may drop the mode, so it stays simple.
- 2026-10-14: the statusline refresh stays 3 s; only the per-render cost is cut.
- 2026-10-14: no phantom rebuilds: a menu nobody opens is not rebuilt on a timer, but only where the gain is worth
  it and nothing fragile.
- 2026-10-14: measure everything, cheaply: the knowing must not slow the Mac (one machine-wide sampler, bash
  builtins); our doctors' and collectors' own cost is counted and checked like any own process.
- 2026-10-14: other projects' background programs are shown by harm in Background, never worked or proposed for
  removal: he removes the harmful ones himself. transcriptions-gpt's overlay CPU and daemon writes are accepted,
  never a goal.
- 2026-10-13: Apple/macOS causes are detected and shown red, reported only.
- 2026-10-13: obvious LLM garbage (off-menu profiles, idle unknown LLM dirs) is cleaned unasked by the night's
  `system-doctor tidy`, to the Trash only; any other disk cleanup is his. Retention: his chats 180 days, worker
  transcripts 15, Gemini listen audio 2 (`share/log-stores.json`).
- 2026-10-06: caches are measured, never cleaned by the night; Spotlight is dropped; the bench pool is his, and
  other chats' load is weather, never paused (2026-10-05). («Updater doctor»)

## Open

- Swap (0.3–384 GiB a day 10-16…22) is the owner chat's: footprint under pressure 10-09…15 was 48 % own (bench
  pipelines), claude 11 %, Blender 11 % (`cohort` 8th field).
- `hs-cli-dead-port` (system-ledger, open) is Breakages': a crash moves no System number.
- `cohort`'s cuts undercount small own rows (Method), and `worker-run`'s CPU check is pending: the owner chat's.
