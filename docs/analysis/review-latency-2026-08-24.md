# Review-panel latency: where the wall goes and what cutting it costs

Snapshot: 808 runs / 9693 cells in `~/.claude-profiles/.claudeb/worker-stats/benches`
(the tables of sections 3, 8, 9 and 11 and the replay of section 5 were regenerated on 2026-08-25
from the store as it then stood, 818 runs / 9847 cells; every 21-day window is still cut at
2026-08-24),
2026-07-20..2026-08-24, 738 of them triaged (2730 confirmed findings attributed per cell from
`reported.json` / `verdicts.jsonl`). Every table here is printed by
`docs/analysis/review-latency-stats.py`, which imports the panel's own rules
(`cell_status`, `watchdog_killed`, `cell_pass_duration`, `panel_watchdog_timeouts`,
`panel_stall_timeouts`, `late_review_line`) rather than restating them. Counts drift by a run or
two between invocations because the store is live.

Definitions used throughout:

- **cell duration** — `cell_pass_duration`: one invocation, so a chunked cell's sum is divided by
  its passes, exactly as the watchdog reads it.
- **LATE** — the report's own rule, `duration > max(3 x median, 120s)` (`report.py:31`).
- **panel wall** — the slowest surviving cell, modelled: non-gated cells all start at t=0, and
  OpenCode cells replay `PriorityGate` (limit 5, longest-expected admitted first). Validated
  against the recorded `started`..`finished` of 807 runs: median modelled/recorded 0.96, p90 1.00
  (D3). It is a lower bound — see B7.
- **`duration_ms` excludes gate wait.** `run_opencode` acquires the gate *before* starting its
  clock, so a queued OpenCode cell's wait exists only in `started_at`..`finished_at` minus
  `duration_ms` (401 of 9693 rows carry those stamps; the field is new).

---

## 1. Answers first

**(1) agy really did degrade, and it is Gemini-specific.** Last 14 days vs earlier, median per
invocation: `agy-flash36-high` 59s -> 101s (1.70x), `agy-flash35-high` 99s -> 162s (1.64x),
`agy-flash35-medium` 96s -> 143s (1.49x), `agy-flash36-medium` 63s -> 94s (1.49x),
`agy-pro-high` 157s -> 217s (1.39x). p90 roughly doubled on the same cells (182s -> 398s,
193s -> 355s). Codex is flat over the same window (`sol-high` 1.03x, `sol-low` 0.97x,
`sol-medium` 0.88x), so this is not the machine or the diff sizes. Claude drifted mildly
(`opus-low` 1.50x, `opus-medium` 1.12x, `opus-high` 1.12x). agy's cap-kill rate also rose,
7% -> 9% of its cells (A3).

**(2) The OpenCode slowdown is not the queue and not admission order.** Simulated admission
position shows no degradation down the queue (position 0: median 28s — it is the *longest-expected*
cell, admitted first by design; positions 1-6: 8-17s). Measured gate wait is 0s median, 375s p90 —
and 1148s max (B1, 124 stamped cells once the rows a run stamped per chunk pass are dropped, since
their span is shorter than their summed duration). The real OpenCode latency has three sources, in
order of size:
- **`oc-grok45` is a failure machine.** 562 runs carried it, 78% of them with no grok cell
  completing, the longest such streak 409 runs in a row (B5, per run). Each attempt is 3 x HTTP 503
  with 15s+30s backoff (~47s), and the cell then retries per chunk and per account: 143-329s of
  process wall inside an 8-24 minute `started_at`..`finished_at` span (B8: `oc-grok45-low`,
  duration 329s, span 1445s). The span is queue wait plus the run, not slot occupancy — the stamp
  is taken before the gate is acquired, and the slot is held only for the 329s — so what the cell
  costs a panel is its own place in the queue and the wall it adds, not 24 minutes of a slot.
  It is still the largest latency item on the OpenCode side and it has produced nothing.
- **22% of all OpenCode cells carry the `retrying in` marker** (5xx + backoff): median 56s vs 13s
  on clean cells, and only 9% of them complete.
- **Provider-side variance on a wholly buffered model.** Today's `oc-dsv4flash` 143s and 310s
  cells carry no retry marker at all and `max_quiet_ms` equals their whole duration (304261ms of
  304536ms) — one silent generation, provider-slow. Nothing local caused it and no stall watch can
  see it.

**(3) The two cutoffs were incoherent, and — the important part — cutting harder did not
make panels faster while a cap kill still bought a retry.** This describes the store before the
2026-08-24 rules of section 5 shipped: `cell_retry_cause` then counted `killed · cap` as a retry
cause, so a cut cell cost its cap *plus* a second attempt. Pricing that retry at the pair's
median completion (7 of the 9 cap-kill retries on record completed, section 8), every cap
policy's median saving disappeared: `agy/oc <=300s` moves the median wall
from 483s to 301s with no retry, and to 444s with the retry. Only p90 survives (997s -> 787s).

**(4) The tier word no longer predicts a wall, and three mechanisms explain it.** 18 of the last
20 runs ran over their tier's budget, median overshoot 3.9x; T0 misses its 3-minute budget 95% of
the time. The mechanisms, quantified in sections 7-9: the caps ratchet upward and never down (agy
600s -> 1800s in three weeks against a 40-70% median rise), a cap kill buys a retry that has never
once produced a confirmed finding (0 of 9) and adds a median 7.2 minutes, and the pool walk lets
one cell make seven attempts (280 agy wall-minutes thrown away). agy's stall cap is not missing —
it exists on every agy pair but is anchored on the worst gap ever seen, so a 359s hang sat under a
480s cap and died at the 1120s duration cap instead.

---

## 2. Duration cap (watchdog)

Derived per `(model, effort)` as `max(900, longest completion + 180)`, escalating by one grace per
kill under a three-strike probe (`panel.py:246`). In practice it almost never binds: over all
history the derived caps would cut **24 of 9693 cells (0.2%)**. The agy side runs to 900-1193s,
i.e. `AGY_TIMEOUT_MAX_S = 600` is only a fallback for a pair with no history.

| pair | side | n | med s | p90 s | max s | LATE | cap-killed |
|---|---|---:|---:|---:|---:|---:|---:|
| agy-flash35-medium | agy | 972 | 101 | 215 | 939 | 5% | 109 |
| agy-pro-high | agy | 475 | 172 | 323 | 864 | 2% | 25 |
| agy-flash36-high | agy | 406 | 88 | 272 | 1013 | 11% | 46 |
| opus-medium | claude | 378 | 292 | 564 | 1483 | 1% | 1 |
| opus-high | claude | 174 | 482 | 795 | 1237 | 0% | 1 |
| sol-high | codex | 617 | 343 | 604 | 962 | 0% | 0 |
| sol-max | codex | 32 | 1021 | 1274 | 1766 | 0% | 3 |
| oc-kimik3-off | opencode | 948 | 15 | 41 | 203 | 1% | 3 |
| oc-dsv4flash-off | opencode | 474 | 5 | 48 | 760 | 7% | 18 |

Full table: section A of the script. The derived rule has a structural flaw beyond looseness: it
is keyed on the pair's *own* history, so as Gemini degrades the cap follows it upward —
`agy-flash35-medium`'s 3x-median threshold rose from 288s to 429s in two weeks purely because the
vendor got slower.

**Who owns the wall** (last 14 days, 256 runs): `opus-medium` 21%, `opus-high` 16%,
`agy-pro-high` 9%, `agy-flash37-high` 9%, `agy-flash36-high` 7%, `agy-flash35-medium` 7%,
`oc-dsv4flash` 6%, `agy-flash35-high` 6%. Claude owns ~40% of critical paths and produces the
confirmed findings; agy owns ~38% and is the cheap side. That asymmetry is what the recommendation
turns on.

## 3. Stall cap (streaming silence)

`panel_stall_timeouts` gives every pair with a recorded gap a stall cap of
`max(240, max gap + 120)` (section 5), handed to a cell only under its duration cap. Both caps
below are computed at 2026-08-24 over the 21-day window; the duration cap is what the launch hands
an agy cell at T0-T1 / T2-T3 under the ceiling.

| pair | side | n | med gap s | p95 gap s | max gap s | med gap / med dur | stall cap s | dur cap s |
|---|---|---:|---:|---:|---:|---:|---:|---:|
| agy-flash35-high | agy | 113 | 20 | 136 | 288 | 0.12 | 408 | 480/600 |
| agy-flash35-medium | agy | 124 | 21 | 146 | 359 | 0.12 | 478 | 480/600 |
| agy-flash36-high | agy | 239 | 15 | 358 | 395 | 0.15 | 515 | 480/600 |
| agy-flash36-medium | agy | 131 | 13 | 117 | 151 | 0.14 | 272 | 480/600 |
| agy-flash37-high | agy | 1 | 14 | 14 | 14 | 0.05 | 240 | 445 |
| agy-flash37-medium | agy | 127 | 19 | 116 | 150 | 0.14 | 270 | 480/557 |
| agy-pro-high | agy | 120 | 67 | 187 | 271 | 0.28 | 391 | 480/600 |
| opus-high | claude | 61 | 509 | 886 | 1236 | 1.09 | 1356 | 1417 |
| opus-low | claude | 67 | 181 | 372 | 596 | 1.00 | 716 | 778 |
| opus-medium | claude | 137 | 355 | 684 | 1005 | 1.10 | 1125 | 1663 |
| sol-high | codex | 205 | 72 | 263 | 390 | 0.20 | 511 | 914 |
| sol-low | codex | 144 | 22 | 70 | 274 | 0.31 | 267 | 356 |
| sol-medium | codex | 76 | 39 | 148 | 310 | 0.27 | 340 | 944 |
| oc-dsv4flash-off | opencode | 157 | 6 | 166 | 334 | 1.08 | 455 | 544 |
| oc-kimik3-off | opencode | 174 | 20 | 63 | 184 | 1.12 | 304 | 301 |

Three findings:

1. **The shipped rule qualifies nothing by ratio**: every pair with a recorded gap carries a cap
   (15 of 15), buffered or not. On a wholly buffered model that cap is dead or near-dead by
   construction: `oc-kimik3`'s 304s sits above its 301s duration cap and is not handed, and
   `oc-dsv4flash`'s 455s sits 89s under its 544s duration cap, so a dsv4flash generation that is
   455s silent is stall-killed 89s before the duration cap would have ended it anyway. Comparing
   medians (`med gap / med dur`) is what separates the sides: agy 0.12-0.28 (0.05 on the one
   `agy-flash37-high` completion), codex 0.20-0.31, claude 1.00-1.10, OpenCode 1.08-1.12.
2. **The caps are set from the worst gap in the window**, so on agy they land at 270-515s (240s
   floor on `agy-flash37-high`, n=1) — near the tier ceiling, which makes most of them dead. p95
   gap + 60s would give 176-247s for agy (`agy-flash36-high` 418s, `agy-flash37-high` 74s at n=1).
3. **Stall kills mostly kill working cells, and that is affordable but not a wall win.** All 42
   stall kills on record were retried; 30 retries completed, 20 with findings, 4 with a confirmed
   finding. The stall watch is a hang net that costs a retry, not a latency tool.

## 4. Cutoff simulation

Optimistic column = cap kill ends the cell. `+retry` = the cell's one automatic retry priced at
the pair's median completion (the behaviour before the 2026-08-24 rules; a kill now ends the
cell). Unique lost = confirmed findings on cut cells
that no surviving cell in the same run also found (matched on file+line).

**Last 14 days (256 runs, 3302 cells, 1360 confirmed):**

| policy | cells cut | unique confirmed lost | wall med | -> med (no retry) | -> med (+retry) | wall p90 | -> p90 |
|---|---:|---:|---:|---:|---:|---:|---:|
| current derived | 19 (0.6%) | 0 (0.0%) | 483 | 483 | 483 | 997 | 997 |
| **agy/oc <=300s, rest derived** | **349 (10.6%)** | **26 (1.9%)** | 483 | **301** | 444 | 997 | **787** |
| **agy/oc <=240s, rest derived** | **458 (13.9%)** | **37 (2.7%)** | 483 | **291** | 412 | 997 | **764** |
| LATE rule (3x med, >=120s) | 285 (8.6%) | 37 (2.7%) | 483 | 408 | 412 | 997 | 819 |
| pair p95 (>=60s) | 304 (9.2%) | 83 (6.1%) | 483 | 417 | 425 | 997 | 737 |
| pair p90 (>=60s) | 474 (14.4%) | 142 (10.4%) | 483 | 362 | 453 | 997 | 720 |
| pair 2x median (>=60s) | 513 (15.5%) | 102 (7.5%) | 483 | 334 | 419 | 997 | 720 |
| flat 300s (all sides) | 740 (22.4%) | 575 (42.3%) | 483 | 300 | 517 | 997 | 300 |
| flat 600s (all sides) | 324 (9.8%) | 146 (10.7%) | 483 | 483 | 483 | 997 | 600 |

**All history (808 runs, 9693 cells, 2730 confirmed):**

| policy | cells cut | unique confirmed lost | wall med | -> med (no retry) | -> med (+retry) | wall p90 | -> p90 |
|---|---:|---:|---:|---:|---:|---:|---:|
| current derived | 24 (0.2%) | 0 (0.0%) | 354 | 354 | 354 | 909 | 909 |
| agy/oc <=300s, rest derived | 609 (6.3%) | 39 (1.4%) | 354 | 300 | 354 | 909 | 755 |
| agy/oc <=240s, rest derived | 779 (8.0%) | 52 (1.9%) | 354 | 255 | 342 | 909 | 754 |
| LATE rule (3x med, >=120s) | 621 (6.4%) | 46 (1.7%) | 354 | 316 | 340 | 909 | 761 |
| pair p95 (>=60s) | 753 (7.8%) | 163 (6.0%) | 354 | 316 | 343 | 909 | 729 |
| flat 300s (all sides) | 1653 (17.1%) | 1182 (43.3%) | 354 | 300 | 434 | 909 | 300 |

Per-side cost of `agy 300s / oc 120s` on the recent window: agy 311 of 1444 cells cut (21.5%) for
18 unique confirmed lost, OpenCode 62 of 797 (7.8%) for 18, claude and codex untouched. A flat
300s across all sides loses 575 confirmed findings — 42% of the corpus — because `opus-*` and
`sol-high/xhigh/max` legitimately run 300-1200s and are where the confirmed findings come from.
That is the whole argument for capping by side rather than globally.

## 5. Shipped rules (2026-08-24)

| level | side | rule | numbers |
|---|---|---|---|
| duration | all | per (model, effort), last `CAP_WINDOW_DAYS` days: longest completion with a confirmed finding + grace; thin (<5 such) longest completion of any kind + grace; kills raise nothing | +180s, no floor, no history 900s |
| duration | agy | tier ceiling after the rule | 480s T0/T1, 600s T2/T3; none for Claude/codex |
| stall | all | the pair's longest silent gap in the window + grace; heartbeat on every side (geminib log, codex `--json` events, Claude `stream-json` events) | +120s, floor 240s; none without a gap on record |
| retry | all | a cap or stall kill ENDS the cell, wall wording in its partial output or not; `CELL_ATTEMPTS_MAX` launches per chunk pass, transient waits included, a wall spending none, every chunk read; a Claude stream with no `result` event is bad output, asked once more | 2 |
| tier | agy | `agy-flash37-high-skill` x1 joins T1/T2 | — |

Replayed over the last 21 days by `--section caps` (regenerated 2026-08-25: 521 runs, 6859
cells; caps as of each run from runs finished and triaged before it, a kill ending the cell — a
recorded kill on the final attempt included — and two attempts per pass). The replay answers with two
bounds, because the cap is per pass while the store holds only each attempt's sum over its
passes: a chunked cell whose sum exceeds one pass's cap but not passes x cap may or may not have
been killed. With that band surviving: agy leg 5 of 408 confirmed lost (1.2%; T1 1.2%, T2 2.4%),
Claude 22 of 1137 (1.9%), codex 6 of 337 (1.8%), OpenCode 1 of 143 (0.7%); panel-unique 33 of
2025 (1.63%). With the band cut: agy 22 of 408 (5.4%; T1 11.1%), Claude 102 of 1137 (9.0%),
codex 23 of 337 (6.8%), OpenCode unchanged; panel-unique 145 of 2025 (7.16%) — 8 chunked opus
cells carry most of it. The truth sits between; the band closes only once per-pass durations are
recorded. Wall (band cut): T1 median 7.2 -> 6.7 min, p90 16.3 -> 11.7; T2 9.2 -> 8.8, 16.2 -> 14.0;
agy slowest cell in T1 median 5.2 min, p90 8.0. The max over the window and not a quantile: on
the replay as it stood on 2026-08-24 (before its per-pass and final-kill fixes, not recomputed)
the q95 + 60s variant of the same rule lost 119 panel-unique findings (6.1%) for T1 median 5.3 —
the p90 win is the agy ceiling and the 21-day window, identical under both — and the q95 stall
cap (+60s, floor 120s) cost 18 more panel-unique on top, the max gap + 120s over 240s costs 7.

The recommendation this replaced, kept for the record:

Expected effect on the recent window: panel wall median 483s -> ~300s (-38%), p90 997s -> ~787s
(-21%), at 36 unique confirmed findings lost out of 1360 (2.6%) and no change to the two sides
that produce most of them. The dumb parts are deliberate: two numbers (300s, 120s) instead of a
per-pair table, a ceiling that does not follow a degrading vendor upward, and one rule at the
retry — a cap kill is a verdict, not a suggestion.

Panels routinely exceed the gate: 1272 of the OpenCode completions on record come from runs that
selected 6 or 7 OpenCode cells against a limit of 5, and the overflow cell cannot start until the
first five release a slot. Cutting the panel to 5 is the cheap fix; RAISING
`OPENCODE_MAX_CONCURRENCY` is not recommended on this data — the side already answers 22% of calls
with a 5xx, and more parallelism against one shared gateway is the wrong direction.

Order of work, largest effect first: retire `oc-grok45` (costs nothing, removes the cell whose
queue-plus-run span is 8-24 minutes from every panel that carries it); drop the retry on a cap
kill; then the two ceilings; then the stall qualification fix.

## 6. Recent cases: the last 20 runs (`--section recent-cases`)

Wall is the recorded `started`..`finished`; budget is the tier's own `budget_min`. A cell's tag
chain is one entry per attempt (`cap` = watchdog kill, `stall` = silence kill, `err` = failed
attempt the pool retried, `ok` = completed).

| run | tier | wall m | budget m | 3 slowest cells | cause |
|---|---|---:|---:|---|---|
| 20260824T160204Z-6f10d02 | T0 | 41.8 | 3 | agy-flash35-medium 40.6m `cap>cap` / agy-flash35-high 24.7m `cap>ok` / agy-flash36-medium 20.6m `cap>ok` | 18.7m cap + 21.8m cap = 40.6m |
| 20260823T184900Z-befae91 | T2 | 36.7 | 10 | agy-pro-high 35.0m `cap>cap` / agy-flash36-medium 18.3m `cap>ok` / oc-kimik3 16.0m `cap>ok` | 17.5m cap + 17.5m cap = 35.0m |
| 20260823T202138Z-068923d | T1 | 26.7 | 6 | agy-pro-high 24.1m `err>ok` / agy-flash36-high#2 21.6m `cap>ok` / agy-flash35-high 8.8m `err>ok` | agy-pro-high completed in 24.1m, no cap fired |
| 20260823T123800Z-c472832 | T1 | 46.7 | 6 | agy-pro-high 44.9m `err>err>err>err>err>err>ok` / agy-flash35-medium 31.1m `err>ok` / agy-flash35-high 29.4m `ok` | 7 attempts down the account pool |
| 20260823T132531Z-c472832 | ? | 52.6 | - | opus-high 48.5m `ok` / opus-high#2 39.5m `ok` | opus-high completed in 48.5m, no cap fired |
| 20260823T012519Z-d2f7243 | T1 | 36.1 | 6 | opus-medium 33.9m `ok` / agy-flash35-medium 19.0m `err>err>ok` / agy-pro-high 18.9m `err>ok` | opus-medium completed in 33.9m |
| 20260823T171015Z-3e0879a | T1 | 37.1 | 6 | agy-pro-high 33.8m `ok` / opus-medium 26.6m `ok` / oc-dsv4flash 15.9m `ok` | agy-pro-high completed in 33.8m |
| 20260824T101742Z-c7c5a34 | T1 | 38.5 | 6 | agy-pro-high 32.7m `err>err>ok` / opus-medium 31.6m `ok` / sol-medium-bare 20.0m `ok` | agy-pro-high completed in 32.7m |
| 20260824T123040Z-6575820 | T1 | 24.3 | 6 | agy-pro-high 22.0m `err>err>err>ok` / opus-medium 14.5m `ok` / agy-flash37-medium 8.7m `err` | 4 attempts, the last one completed |
| 20260824T104757Z-df7982b | T2 | 13.7 | 10 | opus-high 11.8m `ok` / sol-high 9.5m `ok` / opus-medium 8.3m `ok` | the healthy shape |

**18 of the last 20 runs ran over their tier's budget, median overshoot 3.9x.** The full 20-row
table is `--section recent-cases`. Two shapes account for all of it:

- **No cap fires and the panel just waits.** 13 of the 20 walls are a cell that *completed* —
  `opus-medium` at 16-34m, `agy-pro-high` at 22-45m — against caps of 1044-1663s. The caps are not
  wrong-headed here; they are simply above the behaviour.
- **A cap fires and the retry doubles it.** 6f10d02 is the clean example: a T0 panel, budget 3
  minutes, wall 41.8 minutes, made of one cell killed at 18.7m and retried into another kill at
  21.8m. Two more agy cells in the same run were killed and retried successfully at 24.7m and
  20.6m.

## 7. Mechanism 1: the cap ratchet (`--section ratchet`)

`timeout_s` is recorded on every row, so the cap the panel actually handed a cell is observable
week by week — nothing below is re-derived. Week 0 = the last 7 days.

| pair | w2 med / cap | w1 med / cap | w0 med / cap | last cap / overall med | 3x med | 2x med |
|---|---|---|---|---:|---:|---:|
| agy-flash35-medium | 97s / 600s | 124s / 1800s | 171s / 1120s | 11.1x | 304s | 203s |
| agy-flash35-high | 102s / 600s | 157s / 1440s | 167s / 1260s | 11.0x | 345s | 230s |
| agy-flash36-high | 65s / 600s | 90s / 1260s | 106s / 1193s | 13.6x | 263s | 175s |
| agy-flash36-medium | 60s / 600s | 81s / 1080s | 95s / 1169s | 16.6x | 211s | 141s |
| agy-pro-high | 160s / 600s | 192s / 900s | 258s / 1260s | 7.3x | 515s | 344s |
| agy-flash37-medium | - | 106s / 1080s | 146s / 1080s | 8.7x | 373s | 249s |
| sol-high | 373s / - | 343s / 1140s | 354s / 1142s | 3.3x | 1029s | 686s |
| opus-medium | 273s / - | 325s / 1347s | 297s / 1663s | 5.7x | 875s | 584s |
| opus-high | 457s / - | 600s / 1441s | 455s / 1417s | 2.9x | 1447s | 965s |
| oc-dsv4flash-off | 5s / 420s | 7s / 1800s | 5s / 1120s | 220.2x | 120s | 120s |
| oc-kimik3-off | 14s / 420s | 16s / 900s | 18s / 900s | 58.9x | 120s | 120s |

Every agy cap doubled in three weeks — 600s to 1080-1800s — while its median rose by 40-70%.
This has an exact origin: **commit `dbb9ff4` (2026-08-16) deleted agy's own bounded timeout**
(`min(AGY_TIMEOUT_MAX_S=600, max(AGY_TIMEOUT_MIN_S, scaled))`) and OpenCode's
(`min(RATER_TIMEOUT_S, max(420, expected * 8))`) in favour of one history-derived cap bounded only
by `RATER_TIMEOUT_S = 1800`. The week boundary in the table is that commit: week 2 agy caps are
333-600s (1222 of 1403 rows at exactly the old 600s ceiling), week 1 onwards they reach 1800s.
`AGY_TIMEOUT_MAX_S = 600` still exists in `catalog.py` but is now only a fallback for a pair with
no history, so nothing bounds agy at 600s any more.

After that the cap can only rise: it is `max(900, longest completion + 180)`, raised to
`killed_cap + 180` on a kill. `oc-dsv4flash` now carries a 1120s cap against a 5s median (220x)
where its old formula gave 420s. A median-anchored rule with a 120s floor would put agy at
211-515s (3x) or 141-344s (2x), OpenCode at the floor, and leave `opus-high`/`sol-high` roughly
where they already are — the ratchet only ever bit the cheap, fast sides.

## 8. Mechanism 2: the retry after a kill (`--section retry`)

| first attempt | completed, confirmed | completed, findings | completed, nothing | killed again | errored | total |
|---|---:|---:|---:|---:|---:|---:|
| cap kill | 0 | 4 | 3 | 2 | 0 | 9 |
| stall kill | 1 | 0 | 0 | 0 | 0 | 1 |
| other (pool walk) | 5 | 18 | 8 | 0 | 37 | 68 |

**A cap-killed cell's retry has never produced a confirmed finding** (0 of 9): 4 returned
findings that triage rejected, 3 returned nothing, 2 were killed again. Wall added by the
recoverable retries: 11 runs, median +7.2m, p90 +17.5m, max +21.8m, 94 minutes in total. Nine is
the whole measurable population, not the whole population: section 2 counts ~206 cap-killed cells,
but a kill's retry left a row of its own only once `superseded` rows were written (late in the
window), so the other retries' outcomes are not on record anywhere — section 11 lists this gap.

Attempts per cell also show the account-pool walk, which is a separate cost from the one in-cell
retry:

| side | cells | 1 attempt | 2 | 3 | 4 | 5+ | wall m in non-final attempts |
|---|---:|---:|---:|---:|---:|---:|---:|
| agy | 3986 | 3942 | 29 | 5 | 4 | 6 | 323 |
| opencode | 3256 | 3218 | 24 | 0 | 6 | 8 | 97 |
| codex | 1592 | 1591 | 1 | 0 | 0 | 0 | 4 |
| claude | 993 | 993 | 0 | 0 | 0 | 0 | 0 |
| grok | 20 | 20 | 0 | 0 | 0 | 0 | 0 |

The rows sum to the 9847 cells the store held on 2026-08-25; `grok` is the retired standalone
side, kept so the sum is the corpus.

35 agy cells spent 280 minutes in attempts that were thrown away — `agy-pro-high` in c472832 walked
the pool six times before its seventh attempt completed, for a 44.9-minute cell.

Measurement gap: a stall retry's first attempt is written as a row on one run only (3 rows in the
whole store carry `stalled_s`), so the 42 stall kills in C2 cost at least their cap each — 5 runs
bounded at >= 5.4m of extra wall — but the true figure is not recoverable.

## 9. Mechanism 3: stall caps and the buffered sides (`--section stall-buffered`)

The premise that agy gets no stall cap is the opposite of what the store says. **agy is the
best-instrumented side there is** — `run_agy` already passes `--log-file` to geminib and hands the
file to `run_streamed` as `watch_paths`, and that log is a real heartbeat: over the last 40 agy
logs, median gap 0s, median p95 gap 3s, median max gap 18s, and one log silent past 180s (191s,
`agy-pro-high~c1`). The gaps in the tables here and in section 3 are something else — the
`max_quiet_ms` the rows recorded over the whole window, up to 395s — and those, not the log, are
what the stall cap is built from, so agy's caps are loose against what the log now shows. All
seven measured agy pairs carry a stall cap (the shipped rule qualifies nothing by ratio).

| pair | side | med gap / med dur | stall cap | dur cap | p95 gap + 60s |
|---|---|---:|---:|---:|---:|
| agy-flash35-high | agy | 0.12 | 408s | 480/600s | 196s |
| agy-flash35-medium | agy | 0.12 | 478s | 480/600s | 206s |
| agy-flash36-high | agy | 0.15 | 515s | 480/600s | 418s |
| agy-flash36-medium | agy | 0.14 | 272s | 480/600s | 177s |
| agy-flash37-high | agy | 0.05 | 240s (n=1) | 445s | 74s |
| agy-flash37-medium | agy | 0.14 | 270s | 480/557s | 176s |
| agy-pro-high | agy | 0.28 | 391s | 480/600s | 247s |
| sol-high | codex | 0.20 | 511s | 914s | 323s |
| sol-low | codex | 0.31 | 267s | 356s | 130s |
| sol-medium | codex | 0.27 | 340s | 944s | 208s |
| opus-low | claude | 1.00 | 716s | 778s | 432s |
| opus-medium | claude | 1.10 | 1125s | 1663s | 744s |
| opus-high | claude | 1.09 | 1356s | 1417s | 946s |
| oc-dsv4flash-off | opencode | 1.08 | 455s | 544s | 226s |
| oc-kimik3-off | opencode | 1.12 | 304s | 301s | 123s |

Nothing is capless under the shipped rule, but two sides' caps say nothing: the opus pairs and
`oc-kimik3` produced no output until they were done, so their recorded silence is their whole
duration (`med gap / med dur` ~ 1.0) and the cap derived from it is a second duration cap — the
opus caps (716-1356s) sit under their duration caps and are handed, `oc-kimik3`'s 304s sits above
its 301s and is not, which makes it the one pair whose only cutoff is the duration cap. For claude
that was a client choice, not a vendor limit: until 2026-08-24 `run_claude` called `claudeb ...
--output-format json`, one blob at the end; the shipped `--output-format stream-json --verbose`
emits per-turn events and gives the opus pairs a real heartbeat, and their caps tighten only as
new completions age the buffered-era gaps out of the 21-day window. `oc-kimik3` is buffered at the
gateway (it is not in `OPENCODE_STREAM_MODELS`); adding `--stream` for it is testable but changes
what the model emits, so it is not a free switch.

The agy problem is therefore not a missing signal but a wrong threshold. The stall cap is anchored
on the **worst gap in the window**, which puts it at 270-515s while p95 gap + 60s is 176-247s
(`agy-flash36-high` 418s). The live case: in 6f10d02 the `agy-flash35-medium~c2` cell recorded a
**359s silent stretch** (`max_quiet_ms`, the same 359s that is now the pair's max gap in section
3) over 1125s — under the stall cap then in force, so nothing fired, and the cell died at the
1120s duration cap 18.7 minutes in. Under the shipped rule that very gap sets the pair's cap at
478s; the p95 + 60s variant (206s) would have fired on it. That run is no longer among the 40
most recent agy logs, which is why the heartbeat table above shows only one gap past 180s.

## 10. Tiers: designed wall vs observed (`--section tiers`)

`budget_min` in `REVIEW_TIERS` is the minutes each tier was sized for, and `board_tier` classifies
a wall by exactly that number.

| tier | budget m | n before 3 wks | med m | n last 3 wks | med m | p90 m | med / budget | over budget |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| T0 | 3 | 1 | 2.2 | 81 | 4.7 | 10.7 | 1.6x | 95% |
| T1 | 6 | 30 | 3.9 | 157 | 8.1 | 18.4 | 1.3x | 63% |
| T2 | 10 | 65 | 9.6 | 177 | 9.8 | 17.5 | 1.0x | 49% |
| T3 | 20 | 4 | 17.7 | 2 | 19.4 | 20.3 | 1.0x | 50% |

Medians still roughly track the budgets at T2/T3, but **T0 is 1.6x its budget and misses it 95% of
the time**, T1 is over 63% of the time, and T0-T2's p90 is 1.8-3.6x its budget (T3, n=2, sits
at 1.0x). The tier word
no longer predicts a wall: T0's p90 (10.7m) is above T2's budget, and T1's p90 (18.4m) is near
T3's. The `n before 3 wks` column is thin for T0/T3 because the `tier` field itself is recent
(551 of 808 runs carry it), so read the old column as context, not as a baseline.

## 11. Where the data is too thin to decide

- **Gate wait / slot occupancy: 401 of 9693 rows carry `started_at`/`finished_at`, and only 12
  runs carry them for 2+ OpenCode cells.** The 1148s hidden wait and the grok span figures are
  unambiguous in those runs but are not a distribution. The wall model uses `duration_ms` and so
  *understates* OpenCode's contribution; a real 6-cell OpenCode panel against a limit of 5 was
  measured at 964s and 1632s of OpenCode-side wall where the model said 143s and 329s.
- **Whether a chunked OpenCode cell re-queues per pass.** The code re-enters
  `OPENCODE_GATE.acquire` on every chunk pass, which the 3.1-minute gaps between grok attempt rows
  are consistent with, but no run stamps individual passes, so it is inference, not measurement.
- **Retry cost after a cap kill: n=9.** 7 completed, at 16s-1308s. "Retry at the pair's median" is
  the honest middle, not a fitted number; the true median saving of any cap sits between the
  no-retry and +retry columns.
- **Newer agy pairs.** `agy-flash37-*` has 31 high / 167 medium completions and only one gap
  sample for high, so its stall cap (240s, the floor) rests on n=1.
- **The cap columns straddle a rule change.** `dbb9ff4` landed 2026-08-16, inside week 1, so the
  600s -> 1800s move in the ratchet table is a formula change plus the ratchet, not the ratchet
  alone. It does not weaken the recommendation (agy lived under a hard 600s ceiling until eight
  days ago) but the per-week cap deltas are not a clean growth rate.
- **Whether agy's degradation is quota-shaped or model-shaped.** The window is two weeks and the
  bench cannot see Antigravity's side; `gemini-family-pooled-quota` is the other candidate and is
  not testable from this store.
- **Attempt-level rows for stall retries.** Only one run writes the killed attempt as its own
  row, so the wall cost of 41 of the 42 stall kills is a lower bound (>= their cap each), not a
  measurement. The same limit makes RB's `stall` row read 1 where C2 counts 42.
- **`n=9` for cap-kill retries and `n=1` for stall-kill retries.** "0 of 9 cap retries produced a
  confirmed finding" is a real zero, but it is a zero out of nine — the retries of the other ~200
  cap-killed cells in section 2 left no attempt row and are unmeasured, the same limit as the
  stall retries above.
- **Tier baselines before 3 weeks ago:** the `tier` field exists on 551 of 808 runs and mostly on
  recent ones, so T0 (n=1) and T3 (n=4) have no usable "before" column. The over-budget shares are
  from the recent window only.
- **Whether `--stream` would help `oc-kimik3`.** It is the one capless OpenCode pair, but turning
  streaming on changes what the gateway emits (see `OPENCODE_STREAM_MODELS`'s own note), so the
  effect on findings is unmeasured.
- **Confirmed-finding attribution for the 70 untriaged runs** is absent, so "unique lost" is a
  count over the triaged corpus only. It undercounts by whatever those runs would have confirmed.

## 12. Overlap and repeat gain (`--section overlap`)

Window: 2026-08-13 23:00 Europe/Kyiv (20:00 UTC) through the last observed run at
2026-08-24 20:22 Europe/Kyiv. There are 202 triaged runs and 1112 run-local confirmed defects;
174 runs contain at least one. Explicit duplicate-to-canonical attribution exists in 22 runs. The
other 180 runs can credit a
duplicate only when its `(file, line)` exactly matches a confirmed finding, so all overlap figures
below are lower bounds wherever the triage used a semantic duplicate at a different line.

The answer for a walled Claude pool is stark: across all 174 non-empty runs, the agy union delivers
216/1112 confirmed defects (19%), versus 921/1112 (83%) for opus + sol and 68/1112 (6%) for
OpenCode. The complete 174-row run table is printed by `--section overlap`; its micro-total and the
current-tier cuts are:

| population | n runs | n defects | agy | opus + sol | OpenCode |
|------------|-------:|----------:|----:|------------:|---------:|
| all non-empty runs | 174 | 1112 | 216/1112 (19%) | 921/1112 (83%) | 68/1112 (6%) |
| T0 current agy composition | 6 | 14 | 1/14 (7%) | 13/14 (93%) | 0/14 (0%) |
| T1 current agy composition | 0 | 0 | - (n=0) | - (n=0) | - (n=0) |
| T2 current agy composition | 0 | 0 | - (n=0) | - (n=0) | - (n=0) |
| T3 current agy composition | 0 | 0 | - (n=0) | - (n=0) | - (n=0) |

The tier rows require the current `REVIEW_TIER_AGY` composition to be present in full, and
`agy-flash37-high-skill` joined T1/T2 on 2026-08-24, so those rows stay at n=0 until runs under
the new composition accrue; the previous composition gave T1 111/422 (26%) over 67 runs and T2
60/402 (15%) over 51. T0 and T3 are too thin for a policy conclusion. The established cells alone cover 3-8% on their eligible
runs; the initial Flash 3.7 benchmark is much denser:

| agy cell | n runs | n defects | coverage |
|----------|-------:|----------:|---------:|
| flash35-medium | 127 | 849 | 43/849 (5%) |
| flash35-high | 128 | 850 | 39/850 (5%) |
| flash36-medium | 128 | 850 | 41/850 (5%) |
| flash36-high | 123 | 842 | 67/842 (8%) |
| flash37-medium | 136 | 880 | 45/880 (5%) |
| flash37-high | 17 | 53 | 29/53 (55%) |
| flash37-low | 9 | 36 | 11/36 (31%) |
| pro-high | 122 | 836 | 29/836 (3%) |

### 12.1 Agy overlap

Each matrix cell is `shared / row-cell confirmed defects`, conditioned on both cells being in the
run. Copies are folded into their model x effort family.

| row cell | flash35-medium | flash35-high | flash36-medium | flash36-high | flash37-medium | flash37-high | flash37-low | pro-high |
|----------|---------------:|-------------:|---------------:|-------------:|---------------:|-------------:|------------:|---------:|
| flash35-medium | - | 9/43 (21%) | 10/43 (23%) | 16/42 (38%) | 5/43 (12%) | 0/1 (0%) | - (n=0) | 2/42 (5%) |
| flash35-high | 9/38 (24%) | - | 9/39 (23%) | 10/38 (26%) | 6/39 (15%) | 0/1 (0%) | - (n=0) | 3/38 (8%) |
| flash36-medium | 10/41 (24%) | 9/41 (22%) | - | 17/41 (41%) | 6/41 (15%) | - (n=0) | - (n=0) | 1/41 (2%) |
| flash36-high | 16/67 (24%) | 10/67 (15%) | 17/67 (25%) | - | 10/66 (15%) | - (n=0) | - (n=0) | 4/67 (6%) |
| flash37-medium | 5/25 (20%) | 6/25 (24%) | 6/25 (24%) | 10/25 (40%) | - | 11/19 (58%) | 4/19 (21%) | 2/25 (8%) |
| flash37-high | - (n=0) | - (n=0) | - (n=0) | - (n=0) | 11/26 (42%) | - | 8/26 (31%) | - (n=0) |
| flash37-low | - (n=0) | - (n=0) | - (n=0) | - (n=0) | 4/11 (36%) | 8/11 (73%) | - | - (n=0) |
| pro-high | 2/29 (7%) | 3/29 (10%) | 1/29 (3%) | 4/29 (14%) | 2/29 (7%) | - (n=0) | - (n=0) | - |

| agy cell | n runs | n instances | raw confirmed | n runs hit | n caught defects | another agy | opus-* | sol-* | OpenCode | any non-agy | nobody else |
|----------|-------:|------------:|--------------:|-----------:|-----------------:|------------:|-------:|------:|---------:|------------:|------------:|
| flash35-medium | 137 | 163 | 29 | 33 | 43 | 21/43 (49%) | 14/43 (33%) | 7/43 (16%) | 3/43 (7%) | 19/43 (44%) | 17/43 (40%) |
| flash35-high | 138 | 162 | 28 | 26 | 39 | 16/39 (41%) | 16/39 (41%) | 2/39 (5%) | 1/39 (3%) | 17/39 (44%) | 17/39 (44%) |
| flash36-medium | 137 | 161 | 21 | 28 | 41 | 22/41 (54%) | 17/41 (41%) | 10/41 (24%) | 1/41 (2%) | 23/41 (56%) | 11/41 (27%) |
| flash36-high | 133 | 309 | 45 | 46 | 67 | 31/67 (46%) | 23/67 (34%) | 13/67 (19%) | 1/67 (1%) | 30/67 (45%) | 26/67 (39%) |
| flash37-medium | 151 | 190 | 24 | 25 | 45 | 24/45 (53%) | 18/45 (40%) | 5/45 (11%) | 0/45 (0%) | 19/45 (42%) | 12/45 (27%) |
| flash37-high | 28 | 43 | 16 | 10 | 29 | 16/29 (55%) | 0/29 (0%) | 0/29 (0%) | 0/29 (0%) | 0/29 (0%) | 13/29 (45%) |
| flash37-low | 15 | 24 | 10 | 5 | 11 | 9/11 (82%) | 0/11 (0%) | 0/11 (0%) | 0/11 (0%) | 0/11 (0%) | 2/11 (18%) |
| pro-high | 131 | 155 | 22 | 25 | 29 | 6/29 (21%) | 10/29 (34%) | 3/29 (10%) | 3/29 (10%) | 14/29 (48%) | 12/29 (41%) |

`n runs` is distinct panels; `n instances` counts final `rater_runs` rows after folding `#`. Thus
the independent 43/24/187 figures are instances: Flash37 high is 43 instances across 28 runs, low
is 24 across 15, and opus-medium is 187 across 163. `raw confirmed` counts literal confirmed
verdict rows. `n caught defects` additionally credits triage duplicate links, so high is 16 raw
confirmed but 29 caught defects; 13/29 were caught by nobody else. Low is 10 raw / 11 attributed.
The independent exact-key check is also reproduced: 13/16 high confirmed rows have no report at
the same `(file, line)` from another folded cell family.

The agy cells are not interchangeable. Flash37 low overlaps high on 8/11 defects (73%); high still
has 13/29 (45%) nobody else caught. Pro-high has the lowest overlap with established agy cells
(3-14%).

### 12.2 Repeat gain and wall cost

| cell | n runs | #2 adds >=1 | mean added | #2 adds panel-unique | mean unique | added total | unique total |
|------|-------:|-------------:|-----------:|---------------------:|------------:|------------:|-------------:|
| flash35-high | 1 | 0/1 (0%) | 0.00 | 0/1 (0%) | 0.00 | 0 | 0 |
| flash35-medium | 3 | 0/3 (0%) | 0.00 | 0/3 (0%) | 0.00 | 0 | 0 |
| flash36-high | 128 | 24/128 (19%) | 0.23 | 14/128 (11%) | 0.12 | 29 | 15 |
| flash36-medium | 1 | 0/1 (0%) | 0.00 | 0/1 (0%) | 0.00 | 0 | 0 |
| flash37-high | 15 | 4/15 (27%) | 0.60 | 3/15 (20%) | 0.20 | 9 | 3 |
| flash37-low | 9 | 3/9 (33%) | 0.33 | 1/9 (11%) | 0.11 | 3 | 1 |
| flash37-medium | 16 | 4/16 (25%) | 0.44 | 2/16 (12%) | 0.25 | 7 | 4 |
| pro-high | 1 | 0/1 (0%) | 0.00 | 0/1 (0%) | 0.00 | 0 | 0 |
| oc-dsv4flash | 100 | 5/100 (5%) | 0.07 | 1/100 (1%) | 0.01 | 7 | 1 |
| oc-grok45-low | 53 | 0/53 (0%) | 0.00 | 0/53 (0%) | 0.00 | 0 | 0 |
| oc-kimik3 | 102 | 27/102 (26%) | 0.27 | 20/102 (20%) | 0.21 | 28 | 21 |
| opus-high | 2 | 0/2 (0%) | 0.00 | 0/2 (0%) | 0.00 | 0 | 0 |
| opus-low | 1 | 0/1 (0%) | 0.00 | 0/1 (0%) | 0.00 | 0 | 0 |
| opus-medium | 1 | 0/1 (0%) | 0.00 | 0/1 (0%) | 0.00 | 0 | 0 |
| sol-high | 1 | 0/1 (0%) | 0.00 | 0/1 (0%) | 0.00 | 0 | 0 |
| sol-high-bare | 63 | 28/63 (44%) | 0.70 | 18/63 (29%) | 0.43 | 44 | 27 |

The low-self-overlap cells, on in-panel evidence, are `sol-high-bare`, `oc-kimik3`, and
`agy-flash36-high`; their repeats add at least one defect in 44%, 26%, and 19% of runs. Flash37
high/medium/low also add in 27%/25%/33%, but at only n=15/16/9. The near-deterministic/no-gain
group is `oc-dsv4flash` (5%, only 1% panel-unique) and `oc-grok45-low` (0%).

| cell | n runs | #2 panel slowest | #2 slower than #1 | mean +m vs #1 | mean panel +m | mean +m when >0 | max panel +m |
|------|-------:|-----------------:|------------------:|--------------:|--------------:|----------------:|-------------:|
| flash35-high | 1 | 0/1 (0%) | 0/1 (0%) | 0.00 | 0.00 | 0.00 | 0.00 |
| flash35-medium | 3 | 0/3 (0%) | 0/3 (0%) | 0.00 | 0.00 | 0.00 | 0.00 |
| flash36-high | 128 | 3/128 (2%) | 58/128 (45%) | 1.12 | 0.14 | 5.89 | 12.78 |
| flash36-medium | 1 | 0/1 (0%) | 1/1 (100%) | 0.91 | 0.00 | 0.00 | 0.00 |
| flash37-high | 15 | 7/15 (47%) | 7/15 (47%) | 0.90 | 0.63 | 1.36 | 4.40 |
| flash37-low | 9 | 0/9 (0%) | 6/9 (67%) | 0.55 | 0.00 | 0.00 | 0.00 |
| flash37-medium | 16 | 2/16 (12%) | 9/16 (56%) | 0.78 | 0.15 | 1.19 | 2.37 |
| pro-high | 1 | 0/1 (0%) | 0/1 (0%) | 0.00 | 0.00 | 0.00 | 0.00 |
| oc-dsv4flash | 100 | 10/100 (10%) | 56/100 (56%) | 1.49 | 0.58 | 5.83 | 11.24 |
| oc-grok45-low | 53 | 0/53 (0%) | 25/53 (47%) | 0.00 | 0.00 | 0.00 | 0.00 |
| oc-kimik3 | 102 | 0/102 (0%) | 59/102 (58%) | 0.17 | 0.00 | 0.00 | 0.00 |
| opus-high | 2 | 0/2 (0%) | 1/2 (50%) | 0.02 | 0.00 | 0.00 | 0.00 |
| opus-low | 1 | 0/1 (0%) | 0/1 (0%) | 0.00 | 0.00 | 0.00 | 0.00 |
| opus-medium | 1 | 0/1 (0%) | 1/1 (100%) | 6.26 | 0.00 | 0.00 | 0.00 |
| sol-high | 1 | 0/1 (0%) | 1/1 (100%) | 4.44 | 0.00 | 0.00 | 0.00 |
| sol-high-bare | 63 | 1/63 (2%) | 26/63 (41%) | 0.52 | 0.00 | 0.12 | 0.12 |

`flash36-high#2` is slowest in only 3/128 panels. Its unconditional max-tail cost is 0.14 minutes;
when it does stretch the panel the mean is 5.89 minutes and the maximum is 12.78. `oc-kimik3#2`
never sets the panel wall in n=102. `oc-dsv4flash#2` is the bad trade: it sets the wall in 10/100,
costs 0.58 minutes per panel on average, and adds a panel-unique defect only once. Flash37-high#2
has real gain but is the panel tail in 7/15 and adds 0.63 minutes per panel, so one copy wins.

### 12.3 Same-commit attempts

| cell | 1 attempt | 2 attempts | 3 attempts | +2nd pp | +3rd pp | reading |
|------|----------:|-----------:|-----------:|--------:|--------:|--------:|
| flash35-high | - (c=0,a=0,d=0) | - (c=0,a=0,d=0) | - (c=0,a=0,d=0) | - | - | too thin |
| flash35-medium | - (c=0,a=0,d=0) | - (c=0,a=0,d=0) | - (c=0,a=0,d=0) | - | - | too thin |
| flash36-high | - (c=0,a=0,d=0) | - (c=0,a=0,d=0) | - (c=0,a=0,d=0) | - | - | too thin |
| flash36-medium | - (c=0,a=0,d=0) | - (c=0,a=0,d=0) | - (c=0,a=0,d=0) | - | - | too thin |
| flash37-high | 2.9% (c=7,a=36,d=235) | 4.8% (c=7,a=36,d=235) | 6.1% (c=7,a=36,d=235) | 1.8 | 1.3 | mixed |
| flash37-low | 1.2% (c=7,a=24,d=235) | 1.9% (c=7,a=24,d=235) | 2.5% (c=7,a=24,d=235) | 0.7 | 0.6 | repeat adds almost nothing |
| flash37-medium | 2.1% (c=7,a=31,d=235) | 3.5% (c=7,a=31,d=235) | 4.7% (c=7,a=31,d=235) | 1.4 | 1.2 | mixed |
| pro-high | - (c=0,a=0,d=0) | - (c=0,a=0,d=0) | - (c=0,a=0,d=0) | - | - | too thin |

`c/a/d` is commits / observed attempts / known defects. The corrected window contains seven
known-defect commits for every Flash37 effort. High has a modest +1.8 percentage-point second
attempt; medium +1.4; low only +0.7 and is the nearest to deterministic. Every older agy cell has
n=0 comparable commits in this window.

### 12.4 Recommendation

| cell | n runs | n instances | raw confirmed | n caught defects | n #2 runs | #2 adds | #2 unique | corpus n>=2 commits | recommendation | evidence |
|------|-------:|------------:|--------------:|-----------------:|----------:|---------:|----------:|--------------------:|---------------:|---------:|
| flash35-medium | 137 | 163 | 29 | 43 | 3 | 0/3 (0%) | 0/3 (0%) | 0 | 1 copy | thin |
| flash35-high | 138 | 162 | 28 | 39 | 1 | 0/1 (0%) | 0/1 (0%) | 0 | 1 copy | thin |
| flash36-medium | 137 | 161 | 21 | 41 | 1 | 0/1 (0%) | 0/1 (0%) | 0 | 1 copy | thin |
| flash36-high | 133 | 309 | 45 | 67 | 128 | 24/128 (19%) | 14/128 (11%) | 0 | 2 copies | usable |
| flash37-medium | 151 | 190 | 24 | 45 | 16 | 4/16 (25%) | 2/16 (12%) | 7 | 1 copy | usable |
| flash37-high | 28 | 43 | 16 | 29 | 15 | 4/15 (27%) | 3/15 (20%) | 7 | 1 copy | usable |
| flash37-low | 15 | 24 | 10 | 11 | 9 | 3/9 (33%) | 1/9 (11%) | 7 | 1 copy | thin |
| pro-high | 131 | 155 | 22 | 29 | 1 | 0/1 (0%) | 0/1 (0%) | 0 | 1 copy | thin |
| oc-dsv4flash | 106 | 206 | 9 | 15 | 100 | 5/100 (5%) | 1/100 (1%) | 0 | 1 copy | usable |
| oc-grok45-low | 109 | 162 | 0 | 0 | 53 | 0/53 (0%) | 0/53 (0%) | 0 | drop | usable |
| oc-kimik3 | 104 | 206 | 47 | 56 | 102 | 27/102 (26%) | 20/102 (20%) | 0 | 2 copies | usable |
| opus-high | 80 | 105 | 249 | 266 | 2 | 0/2 (0%) | 0/2 (0%) | 0 | 1 copy | thin |
| opus-low | 86 | 110 | 65 | 105 | 1 | 0/1 (0%) | 0/1 (0%) | 0 | 1 copy | thin |
| opus-medium | 163 | 187 | 366 | 446 | 1 | 0/1 (0%) | 0/1 (0%) | 0 | 1 copy | thin |
| sol-high | 64 | 88 | 26 | 43 | 1 | 0/1 (0%) | 0/1 (0%) | 0 | 1 copy | thin |
| sol-high-bare | 63 | 174 | 97 | 145 | 63 | 28/63 (44%) | 18/63 (29%) | 0 | 2 copies | usable |

The only robust two-copy wins are `flash36-high`, `oc-kimik3`, and `sol-high-bare`. Flash37-high
flips from **drop** to **1 copy**: it caught 29 defects, 13 nobody else caught, and its second copy
is too often the tail. Flash37-low also flips to **1 copy**; it has real first-copy coverage but
high self-overlap and only n=9 in-panel repeats. `oc-dsv4flash#2` is unique in 1/100;
`oc-grok45-low#2` adds nothing in 53.

For an agy-only panel, the fixed common cohort is n=119 runs / 828 defects and requires all six
established cells plus `flash36-high#2`, so every candidate below has the same denominator:

| composition | n runs | n defects | coverage | median wall m | coverage pp/m |
|-------------|-------:|----------:|---------:|--------------:|--------------:|
| flash36-medium, flash36-high x2, flash37-medium | 119 | 828 | 104/828 (13%) | 3.07 | 4.09 |
| flash36-medium, flash36-high x2 | 119 | 828 | 90/828 (11%) | 2.79 | 3.89 |
| flash35-high, flash36-medium, flash36-high x2, flash37-medium | 119 | 828 | 127/828 (15%) | 4.23 | 3.63 |
| flash36-medium, flash36-high, flash37-medium | 119 | 828 | 82/828 (10%) | 2.79 | 3.55 |
| flash36-medium, flash36-high | 119 | 828 | 66/828 (8%) | 2.36 | 3.38 |

Within the comparable established-cell cohort, the best measured coverage per median wall-minute
remains **flash36-medium x1, flash36-high x2, flash37-medium x1**. It delivers 13% of the full
panel's defects on that cohort. The corrected Flash37 sweep is disjoint, so inserting high into
that 13% calculation would mix denominators. Operationally, when Claude is walled, add
**flash37-high x1** to that fallback: its first-copy evidence is strong and the old drop decision
was false. Do not buy high x2 (tail in 7/15) or treat low as mandatory until a shared-cohort run
measures the combined panel; low remains a one-copy cell when selected.
