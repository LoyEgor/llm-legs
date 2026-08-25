# Review-bench waits — where panel wall clock goes beyond the slowest cell (2026-08-24)

Every recorded run with both a panel wall and per-cell durations: 781 runs. For each,
`excess = panel wall − slowest completed cell's duration`; 526 runs had excess > 5 s, totalling
**1499 min**. A run's excess is split across the mechanisms its
record supports, in the order below and up to what is left, so a run appears in every bucket it
funds: the run counts are not disjoint (they sum to 1125 over those 526 runs) and the minutes
are.
Analyzer: `docs/analysis/review-waits-stats.py` (imports rbench, reads the recorded benches).

Reading caveats:
- `duration_ms` starts after the OpenCode gate is acquired, and `started_at`/`finished_at` per
  attempt exist in only 26 runs — gate-queue and 5xx-walk shares are inferred (panel size vs the
  gate limit, the `retrying in Ns` stderr marker), not stamped.
- Transient pool-walk attempts were discarded from meta at record time, so a cell that walked
  accounts before answering shows only its last attempt; part of "unattributed" is this.

## Mechanisms, ranked by minutes

| mechanism | runs | min | share |
|---|---|---|---|
| failed cell held the panel (errored last, outlived every completed cell) | 102 | 430.0 | 29% |
| verify phase (serial, strictly after all cells) | 459 | 415.2 | 28% |
| timed-out cell held the panel | 38 | 342.0 | 23% |
| recorded retries / pool walk (superseded attempts in meta) | 24 | 88.6 | 6% |
| oc gate queue + failed-cell 5xx walk, inferred (>5 oc cells and the 5xx marker) | 224 | 88.2 | 6% |
| oc failed-cell 5xx walk, unrecorded (inferred from the marker alone) | 70 | 62.6 | 4% |
| unattributed | 100 | 43.5 | 3% |
| oc gate queue, inferred (>5 oc cells, no marker) | 108 | 29.5 | 2% |

Excess distribution: median 21 s, p90 355 s, max 2492 s; 156 runs exceed
max(60 s, half the slowest cell). Verify phase alone: 479 runs, median 26 s, p90 115 s,
max 1261 s, 416 min total.

Top 10 runs by excess (min): b451096 T2 41.5 (oc failed-cell 5xx walk; wall 50.1, slowest
completed opus-high 8.6); befae91 T2 29.4 (timed-out cell); 20260724T184811Z-143fc2f 27.2
(timed-out); 20260726T110738Z-8553616 24.3 (timed-out); c8368e8 T2 24.2 (oc gate + 5xx);
f8b9780 T1 23.8 (timed-out); 20260722T021326Z-8553616 23.6 (timed-out); 81d78b5 T1 21.0
(verify phase); ff0c1fa T2 20.2 (failed cell); 6f10d02 T0 20.0 (recorded retries).

Held-panel breakdown (the cell that outlived everything): agy-flash35-medium failed 162.6 min
(31 runs), oc-dsv4flash timed-out 73.9 (9) + failed 48.5 (7), agy-flash36-high timed-out 60.2,
agy-pro-high 52.6 + 46.3, sol-max 41.7. The oc bucket totals 180.8 min; the agy/codex buckets
(~470 min) belong to the cap/watchdog system, out of this change's scope.

## The OpenCode leg alone

Per attempt across all recorded runs (model = completed, failing = errored attempts' duration,
waiting = stamped gate wait where attempts carry timestamps, n=26 runs):

| cell | attempts | fail % | model min | failing min | waiting min | 5xx-marker cells |
|---|---|---|---|---|---|---|
| oc-grok45-low | 1166 | 79% | 110.9 | 546.1 | 70.0 | 587 |
| oc-dsv4flash | 627 | 23% | 208.4 | 373.6 | — | — |
| oc-kimik3 | 1358 | 30% | 339.1 | 89.5 | — | — |

oc-dsv4flash's failing share is 64% of its total minutes — dominated by in-model
reasoning-strategy walks (a single in-gate attempt measured at 846 s), not by the gateway.
Worst account by failing minutes: opencode-go-dioqktn 314.2; best: opencode-go-prod 3.4.
406 of 781 runs launched more than the gate's 5 concurrent oc cells (819 excess min live in
those runs across mechanisms).

## What this justified (shipped with this analysis)

- Retire oc-grok45 (all copies, all efforts): 79% of 1166 attempts failed, 546 failing minutes
  vs 111 model minutes, in-gate 5xx walks, 0 confirmed defects since 2026-08-13.
- Leg drops oc-dsv4flash#2 (unique contribution 1/100 in the triage window); eco leg is now
  `oc-kimik3 x2, oc-dsv4flash`, max `oc-kimik3 x3, oc-dsv4flash` — every tier fits the gate.
- `cap_opencode_panel`: a tier-composed panel never selects more oc cells than the gate admits
  (5). A hand-written `--raters` stays ungated, which is what that surface is for.
- `opencode-go --retries 1` from the bench: the client's internal 15–45 s 5xx sleeps happened
  inside a held gate slot while the bench already retries the same failure off-gate — and the
  bench's own transient class now covers the whole 5xx family and a curl-level HTTP 000, which is
  what the client retried.
- Verification starts per cell as its review lands instead of serially after the whole panel —
  the 415-min serial phase overlaps cell time. One shared slot cap holds every verifier call in
  flight to the same ceiling the serial pass had, and each cell records the part of its
  verification that actually extended the wall.
