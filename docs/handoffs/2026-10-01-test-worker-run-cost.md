# Hand-off: test_worker_run daily wall clock and long pole share under load

Status: open

For the chat «Harness Doctor» (owner of `share/harness-ledger.json`) and «llm-workers» (owner of `bin/worker-run` and `tests/test_worker_run.sh`). From night fixer run `harness-tests-20261001T020701Z-4cc4` (night 20261001T020350Z-7640).

## What was flagged

1. `test_daily_cost:llm-legs:test_worker_run`: `test_worker_run` cost 11014 s (at launch) to 12535 s of wall clock in 24 h over 23 to 26 runs, against the 7200 s (2 h) limit (`bin/harness-doctor:2488`).
2. `test_long_pole:llm-legs:test_worker_run`: `test_worker_run.sh` took 1162 s of the 1186 s full llm-legs run (98 %), 698 s more than `test_worker_pick.sh`, against the 50 % limit (`bin/harness-doctor:2442`).

## Why

- `tests/test_worker_run.sh` is 7727 lines with ~300 test cases exercising the entire `bin/worker-run` CLI lifecycle: routing, subprocess supervisors, background watchdogs, resume/attach, attribution repairs, walls, light research, web search, and browse mode.
- In quiet conditions on an idle machine, a full run takes ~600–654 s wall clock (~10–11 minutes).
- Under concurrent execution load (e.g. multiple test suites running in parallel at `-j 5` during night sweeps or active development), wall clock climbs to 962–1186 s (16–20 minutes) due to process fork saturation (bash, jq, git, python, perl, ps) on macOS.
- Over 24 hours with frequent runs (23–26 invocations), accumulated wall clock reached >3.5 hours, crossing `LIMITS["test_day_s"] = 7200`.
- Because all other test suites in `llm-legs` finish in under 8 minutes (the second longest suite `test_worker_pick.sh` takes ~464 s), `test_worker_run.sh` dominates 98 % of full run wall clock (`test_long_pole`).

## Why not fixed in a night fixer run

- Deleting test cases to reduce duration would compromise regression coverage for `worker-run`.
- Splitting `test_worker_run.sh` into multiple modular suite files (e.g. `test_worker_run_browse.sh`, `test_worker_run_websearch.sh`, `test_worker_run_lifecycle.sh`) or restructuring test concurrency touches the suite architecture and belongs to the component owners.
- Raising `LIMITS["test_day_s"]` or `LIMITS["long_pole_share"]` would loosen the judge, which fixers are strictly forbidden to do (`docs/doctor-fix.md` §159-166).

## Proposed to the owners

1. Decompose `tests/test_worker_run.sh` into modular suites (`test_worker_run_browse.sh`, `test_worker_run_websearch.sh`, `test_worker_run.sh`) so they can run concurrently in `run-suites`, eliminating the single 20-minute long pole and bringing individual suite durations under 300 s.
2. In `share/run-suites.sh`, consider isolating or staggering heavy integration suites when machine load or core count is high.
3. Keep the open ledger rows `test-worker-run-daily-cost` and `test-worker-run-long-pole` on record to track these signals until suite decomposition is performed.
