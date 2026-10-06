# Hand-off: collector:run judges the machine's saturation, not the collector

Status: open

To: «Harness Doctor» (`share/harness-ledger.json` `owner`). Row `collector-run-cpu-starved`,
regressed 2026-10-04 after the 2026-10-04 fix (a run over `collector_s` while a run-suites or
night-fixer slot is held is a watch). Written by night fixer harness-doctor-20261006T032859Z-52ce.

## Facts (24 h to 2026-10-06 03:34Z, `<doctors>/collector-runs.jsonl` joined with `samples.jsonl`)

- 136 harness runs, 79 over 30 s; 5 of them with no slot held, so red: 20:04, 01:10, 01:21,
  01:43 and 03:24 UTC, wall 119-654 s on 13-27 CPU-s, busy 99.9 % at each.
- 03:24 is the night's own base phase (night-run pressing 4 repos, the code doctor's refresh and
  judge, then the system doctor's harvest): requested work that holds no slot. The other four are
  load outside any slot (Egor's work, benchmarks), weather by `load-is-weather`.
- Wall is about `cpu_s` x load / cores, as on 2026-10-04. Its own CPU was median 11.6 s (2026-10-04:
  7.9). This run cut 4.9 CPU-s of it (`change_impact` scanned every journal once per change and
  window; now sorted once, bisected and cached, output proven identical on live data), leaving
  `hook_view` (7.6 s of 24 s profiled) as the dearest part.

## Decide

1. Judge the collector's own `cpu_s` (from `collector-runs.jsonl`) against a CPU limit and keep wall
   as shown context; contention of any source stops reading as the doctor's fault.
2. Or widen "slot held" to a live night-run (its `<nights>/.lock`): covers 1 of the 5 reds only.

Either changes the judge, so a fixer may not. Recommendation: 1, since the row's own title says wall
is the saturated machine's; calibrate the limit on the post-cut median (about 7 CPU-s).
