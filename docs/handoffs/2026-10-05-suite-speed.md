# Hand-off: suite speed, measured 2026-10-05

Status: open — To: Harness Doctor

Source: `~/.cache/run-suites/runs.jsonl`, passing llm-legs suites over 7 days, medians. 131 suites: 2772 s CPU, 12137 s summed wall.

| suite | wall s | CPU s | cost |
|---|---|---|---|
| worker_pick | 1111 | 224 | ~400 `worker-pick` runs, 0.65 s CPU, ~326 forks each |
| instruction_gate | 1058 | 264 | gate hook per case |
| statusline_hooks | 834 | 232 | hooks per case; 800 seeds forking `mkdir` + `date` |
| llm_limits | 422 | 160 | `llm-limits.sh`, 0.6 s CPU, 228 forks each |
| llm_limits_grok | 347 | 37 | same collector |
| llm_limits_claudeb | 325 | 37 | same collector |
| worker_run_pool | 311 | 60 | `worker-run` cycles |
| light_research | 301 | 48 | 5 runs: 5-8 s alone, 85 s at nice 10 |
| worker_run_vendor_files | 293 | 59 | `worker-run` cycles |
| worker_run_stamps | 267 | 52 | `worker-run` cycles |

**Cause.** These ten suites sleep less than 10 s in total. Their wall time is the CPU of the code under test, multiplied by the benchmark's load (150-190 on 10 cores): about 3× at nice 0 and 10× at nice 10. sys time is twice user time, so the cost is fork/exec. The lever is the per-call cost of `worker-pick`, the hooks and `llm-limits.sh`. Every chat pays that cost too, so it belongs to the Speed doctor.

**Fixed.**
- `place_set`: builtin clock and a single `mkdir`, about 1800 fewer execs.
- `test_llm_limits.sh`: sets an mtime instead of `sleep 1`.

**Scope is the waste.**
- A `bin/worker-run` change lists 52 suites with 1934 s CPU, 70 % of a full run.
- A `bin/worker-pick` change lists 55 suites.
- So "covering suites" meant a full run per worker.

## Two layers (implemented 2026-10-05)

- **Slow layer:** the 13 suites over 45 s median CPU, 1398 s CPU (50 %). Night full run and Close only; a worker runs one only when it edits that suite.
  - geminib, instruction_gate, light_research, llm_limits, statusline_hooks
  - vendor_fingerprint, worker_pick, worker_pin_gate
  - worker_run_attribution, worker_run_pool, worker_run_stamps, worker_run_vendor_files, worker_run_websearch
- **Fast layer:** everything else. Workers run its affected part.
- **Effect on a `bin/worker-run` change:** 40 suites and 696 s CPU instead of 52 and 1934 s (−64 %).
- **Risk:** a slow-layer regression surfaces in the night run, as a fix job.
- **Mechanism:** the checked-in list `tests/slow-suites`; inside a worker `tests/affected` and `--changed` drop its suites unless edited and print `slow layer skipped: …`; the run row journals `skipped_slow`. `share/affected-suites.sh --slow-refresh` prints the list recomputed from the journal (on 2026-10-05 it adds `test_night_run.sh`); nothing recomputes it at run time.
- **Admission floors:** room only adds slots above the old defaults: suites cores / 3 (2–4) up to 4, night workers cores / 2 (2–8) up to the cores capped at 12.
