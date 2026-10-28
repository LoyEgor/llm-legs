# Hand-off: worker-run run records nobody reads

Status: settled 20261014T013750Z-8004: none is unread (snapshot+files-external: files and run-fold; dirty: UNNAMED/claim; dirty-before: LAST-EDIT/read-only hint; head-before: run-suites, knobs, time_budget; produced: haiku_trial), nothing deleted; row am cut to the reader map, produced tagged for the Haiku trial report
To: next night, a harness fixer

Since the anchors store took over debt attribution (`3abe0bf8`), the worker-to-launcher fold is
`review-anchors run-fold` at the run's end. review-bench no longer reads `<run-dir>/produced`,
`files-external`, `dirty`, `dirty-before-shas` or `head-before`; no `share/rbench` module names them.
`bin/worker-run` still computes and writes them (`record_produced`, `produced_edit_rows`,
`produced_commit_rows`, `record_workdir_dirt`, `take_floor`, …), and shared-invariants row `am`
still describes their legacy claim semantics at length.

Find every remaining reader (`share/chat_names.py` reads `launcher` and `worker-session`; the
snapshot diff may still feed `--changed`/`--owned`/`--base`/`--after` of `run-fold`). Writes no
reader consumes go, with their test pins in `tests/test_consistency.sh` and
`tests/test_worker_run_stamps.sh`; row `am` shrinks to what is still read. A speed fix: prove the
work-not-done per `docs/speed-doctor-design.md`.
