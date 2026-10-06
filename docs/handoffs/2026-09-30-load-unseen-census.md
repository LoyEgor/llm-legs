# Hand-off: load:busy and load:unseen judge the machine, not the harness

Status: open

For «Harness Doctor» (`share/harness-ledger.json` `owner`), rows `load-busy-night-concurrency` and
`load-unseen-suites-statusline`, both back to `open` as weather (night fixer
harness-load-20261006T032928Z-345d). The slot exclusion (option 1 of this handoff, ac75a868) works as
written; every red since comes from load no slot names.

## Facts (quiet samples, both ends `held` 0, since 2026-10-04 17:30)

- 10-04 17:45-22:24: 17 red samples, busy 100 %, unseen 5.6-8.8 cores. 15 of them overlap direct
  suite runs of chats and workers (`bash tests/test_*.sh`, no run-suites slot), summed run time
  13-183 % of each window; what else ran is unrecorded.
- 10-06 03:53-04:55: 9 red, busy 83-95 %, no finished test run: logo-vectorizer-bench tracers
  (`champ42/pipeline.py`, `retrace.py`, `slotrun.py`; memlogd frame 2026-10-06T040532).
- 10-06 06:24: the run's own launch value (busy 99.9 %, unseen 5.5) is one 65 s sample inside the
  night's pre-phase (orchestrator doctors and survey, 06:20-06:29, no slot) while the bench still
  ran (system-doctor hours 2026-10-06T03: `pipeline.py`, `jpeg_pipeline.py` births).

Egor 2026-10-05 (memory load-is-weather): other chats' and benchmarks' load is weather, never to be
paused; the harness must adapt. Five load fixers (2026-09-30 to 10-06) re-measured the same rows.

## Proposed to the owner

1. Dismiss both as `weather`: whole-machine busy belongs to the System doctor, which now attributes
   births and CPU per owner class (`~/.cache/system-doctor/hours`); the harness's own forks keep
   their statusline and hook rows. Recommended.
2. Or judge only the harness's own share: system-doctor `births_top` rows of class `own`.
3. Or widen "requested work" past slots: test-history runs overlapping the sample window and the
   night's pre-phase. It still reds on every benchmark.

Each changes the judge, so no fixer may do it.
