# System (direction 3)

The machine: our own background processes (statusline, Hammerspoon, samplers, collectors, daemons), disk writes,
swap and stores. Only our own processes are worked; Apple and third-party ones are watched, and macOS causes are
report-only. The System doctor's own UX belongs to the owner chat «Передача system-doctor-ux», never a goal here.

## Metric

- Own background CPU-min/day: our processes that run with no order behind them. Test CPU (`run-suites`, tests) is
  Lost time; the work itself (worker-run, image-fanout, agy, night-run, doctor-fix, review-bench, the logo bench) is
  load; transcriptions-gpt is accepted (Decisions).
- SSD GB written a day, swap GiB written a day beside it.

### Baseline (computed 2026-10-16)

The journals start 2026-10-06 (10-06 partly), so the prior window is 3 days. Per covered day: the machine slept part
of 10-10 and 10-11, so 10-09…15 covers 6.31 days.

| per covered day | 10-06…08 (2.73 d) | 10-09…15 (6.31 d) |
|---|---:|---:|
| **own background CPU-min/day** | **126** | **223** |
| same without the statusline (its CPU hid in `claude` until 10-13) | 126 | 130 |
| Hammerspoon | 114 | 94 |
| `statusline.sh` (journal starts 10-13: 286, 173, 128 on 10-13/14/15) | — | 93 |
| memlogd (0 until 10-14, then 32 and 43) | 0 | 12 |
| token-map scan | 7 | 11 |
| doctors and the System doctor's ticks | 5 | 13 |
| **SSD written, GB/day** | **304** | **441** |
| **swap written, GiB/day** | **6.9** | **88.5** |

Method, `python3 -I` over `~/.cache/system-doctor/days.jsonl`, one row per day:
- CPU: Σ the 3rd field (cpu-s) of `cohort` rows owned `own` whose tag ends in Hammerspoon, `statusline.sh`, memlogd,
  `tokenmap/__main__.py`, `*-doctor`, ssd-sampler, llm-refresh, llm-selfcheck or vendor-cli-update, plus `tick_cpu_s`;
  ÷ 60 ÷ (Σ `covered_s` / 86400).
- SSD and swap: Σ `ssd_w_b` ÷ 1e9 and Σ `swapout_b` ÷ 2^30 over the same covered days.
- Statusline per day: Σ column 4 (CPU ms) of `~/.cache/harness-doctor/statusline/<day>.tsv` ÷ 60000; column 5 = 1
  marks a render whose output equalled the previous one.
- `cohort` keeps a day's top 100 items, so an own row under the 100th drops out: on 10-14…16 bench scripts filled the
  list and token-map and the doctors (≤3 CPU-min/day each) went missing. The last window undercounts them.

## Sources

- `~/.cache/system-doctor/days.jsonl`: per day `cohort` (tag, owner, cpu-s, births, written B, read B, wakes,
  footprint B·s under pressure), `ssd_w_b`, `swapout_b`, `covered_s`, `tick_cpu_s`, `births_s`.
- `~/.cache/system-doctor/hours/<day>.jsonl`: the same per hour (`cpu_top`, `hour`).
- `~/.cache/system-doctor/latest.json`: `background` (7-day groups by origin), `measures.ssd_sampled` (the root
  ssd-sampler's write shares, since 10-13), `nightly` (crash and jetsam reports).
- `~/.cache/harness-doctor/statusline/<day>.tsv`: one line a render (start µs, end µs, session, CPU ms, same).
- `~/.cache/speed-doctor/presence/<day>.tsv`: minute, idle seconds, front app. Away = idle ≥ 600 s.
- Ledgers: `share/system-ledger.json` (System doctor), `cpu:` rows of `share/spend-ledger.json` (CPU audits), Speed
  rows of `share/harness-ledger.json`.

## Recurring classes

Ranked 2026-10-16 from the ledgers above and git history (llm-legs, hammerspoon, token-map, claude-setup).

| class | rows | days fixed | instances fixed |
|---|---:|---:|---:|
| the statusline recomputes a section whose inputs did not change | 8 | 3 (10-06, 10-13, 10-14) | 10 |
| a Hammerspoon timer polls on the main thread while nobody looks | 3 | 4 (10-09, 10-10, 10-13, 10-14) | 8 |
| a store rewritten whole instead of its delta (token-map scan, review-anchors memo) | 3 | 2 (10-13, 10-14) | 3 |
| Hammerspoon crashes on a dying `hs` CLI port | 1 | 2 (10-09, 10-14) | 2 |

- Statusline rows: `cpu:statusline/{render,ports,unpushed,work,debt,autonomy}`, `cohort-statusline-renders`,
  `statusline-render-load`. Every audit gives one section its own TTL or key cache; a new section joins uncached,
  and 38–59 % of renders a day still print the line before (63 of 128 CPU-min on 10-15).
- Hammerspoon rows: `cohort-hammerspoon-tab-poll`, `cpu:process/Hammerspoon`, `speed-hs-lag-instruction-watch-walk`
  (iPad pointer trace, instruction-watch walk ×2, tab poll ×3, menu rebuild ×2). 14 files start repeating timers,
  each with its own idle rule; three gate on `Presence.away()` by hand. 10-09…15: 1.83 CPU-min an away hour (51 h)
  against 4.60 present (63 h), so away hours carry ≈ 15 of the 94 CPU-min/day. Method: `hours/<day>.jsonl` (local
  `hour`) joined with that hour's presence minutes; away ≥ 90 % minutes idle ≥ 600 s, present < 10 %; Hammerspoon =
  its `cpu_top` cpu-s, 0 outside the hour's top 12 (14 of the 51 away hours, 8 of the 63 present).
- Whole rewrites: since 10-14 no own background writer passes 1 GB/day (memlogd 0.84 on 10-15), so no goal now.
- `hs-cli-dead-port` came back once after its 10-09 fix (10-14 03:40, SIGTRAP in `CFMessagePortSendRequest`) and not
  since the 10-14 08:19 fix: the 10-14 15:45 Hammerspoon crash nightly also counts is a different bug (Lua assert in
  `luaT_gettmbyobj`). No goal.

## Goals

The pilot works this after Breakages' goals (`bash-cap`, a run outliving the Bash cap, is Breakages'; test CPU is
Lost time). Hammerspoon has no goal (Open). SSD has none: of the sampled writes 10-13…16 (`latest.json`
`measures.ssd_sampled`: 20 samples, 22 min in all), kernel_task wrote 55 % (swap 28 %) and the logo bench's
`$TMPDIR` ≥ 17.5 %. Neither is an own background process.

### goal render-memo: a statusline render with unchanged inputs prints the last line and forks nothing

Class: row 1. The render is a pure function of what it reads.
- llm-legs `bin/statusline.sh`: the render's first step builds one key from what it reads: the session's
  transcript size, the mtimes of the limits store, probe outputs and the repo's `HEAD`/index, and the minute for
  age texts. With the last render's key, it prints the stored line and exits with builtins only. Reading mtimes
  and sizes costs a `stat` fork, ≈ 2.5 CPU ms each (200 `stat -f %m` forks: 0.51 CPU-s); the loadable `stat`
  builtin (`bin/worker-run`'s `enable -f "${BASH%/bin/*}/lib/bash/stat"`) costs ≈ 0, so the key uses it.
- The per-section TTL and key caches the memo covers fold into it, so code shrinks.
- Proof: CPU ms per render, old against new on the same renders: interleaved replay of captured inputs on the same
  machine, unchanged-input renders apart. Beside it from the journal (Σ column 4 ÷ lines, column 5 = 1 apart):
  70.3 ms a render on 10-15 (72.2 unchanged, 68.5 changed), 59.1 on 10-16; renders a day 158k, 163k, 109k, 84k on
  10-13…16 (10-16 partial), shown next to the per-render number, never folded into a CPU-min/day verdict.
- Must not get worse: the line byte-identical to the uncached render on the replay set; a changed input shows on the
  next render; the refresh stays 3 s; Hammerspoon and doctor CPU unchanged.

## Done

| date | change | result | evidence |
|---|---|---|---|
| 10-06 | statusline render cuts | ≈230 → 120 ms CPU a render; interval stays 3 s | `docs/handoffs/2026-10-05-hook-cuts-left.md` |
| 10-13 | ssd-sampler v3 as a system service: per-process writes, CPU, memory | | |
| 10-13 | token-map writes only what changed | writes 1.3 GB/h → 3.5 MB/h | token-map 825b88f |
| 10-13 | Background grouped by project | | |
| 10-13/14 | six statusline sections cut by CPU audit | 286 → 128 CPU-min/day (10-13 → 10-15) | `cpu:statusline/*` |
| 10-14 | Hammerspoon tab poll idle-adaptive | 98, 93 CPU-min/day on 10-14/15, not proven | hammerspoon b4a4941, 75d60db |
| 10-14 | the System doctor's blind spot | | 7fcf0fc1 |

Spawn storm (10-13 research, `docs/system-doctor-design.md`): 920 births a second on 10-13, half of them the
statusline at night, the kernel spending ≈ 43 % of task CPU on their lifecycle; 135 on 10-15.

## Decisions

- The statusline refresh stays 3 s; only the per-render cost is cut.
- Apple causes are reported only. Disk cleanup, the bench pool and Spotlight are Egor's trades.
- transcriptions-gpt's overlay CPU and daemon writes are accepted, never a goal.

## Open

- Swap since 10-12 (46, 30, 398, 79 GiB on 10-12…15): footprint under pressure 10-09…15 is 48 % own (bench pipelines,
  Hammerspoon 3.8 %), claude 11 %, Blender 11 % (`cohort` 8th field). Owner chat.
- memlogd 0 → 32–43 CPU-min/day from 10-14: a new cost (chat-load reads every pid's footprint, 435f5b3f, adf10968)
  or a newly visible tag (memlogd re-execs bash 5, 79f1a3fd). Not settled.
- The statusline has no baseline before 10-13: its CPU sat in `claude`'s reaped children.
- `cohort`'s top-100 cut hides small own rows on bench days (Method). The doctor is the owner chat's.
- The owner chat's pending check of `worker-run`'s CPU.
- Hammerspoon (row 2): an away-timer helper was dropped as a goal (≈ 15 of 94 CPU-min/day, and its away-hour measure
  breaks on `cpu_top`'s top 12); present hours, ≈ 80 of 94, have no class or goal yet.
