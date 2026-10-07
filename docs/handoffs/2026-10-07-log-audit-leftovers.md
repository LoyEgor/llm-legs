# Log audit leftovers (night 20261006T233611Z-7777, run harness-doctor-20261006T234242Z-1fa6)

Status: settled 20261007T213650Z-7b98: items 1, 3, 4, 6, 7 fixed with tests red on old code, 8 proven by live runs, 2, 5 and 9 kept with reasons in their ledger rows.

Each item is ledger row `log_audit:<id>` in `share/harness-ledger.json`; its note carries the verdict.

1. **launch-gate-refusals-first-attempt**: fixed. Relays pass `--account`/`--model` exactly as their prompt's
   `ACCOUNT:`/`MODEL:` lines say (claude-setup `agents/*-worker.md`; `tests/test_consistency.sh`).
   Same cause: `worker-launch-gate-account-flag`.
2. **sleep-poll-loops-waiting**: kept. `worker-run wait` returns when the run ends, so longer rounds save
   only relay turns. The logo-bench "all busy, 4 of 8 slots open" message is correct.
3. **wip-owner-misattribution**: fixed. A Bash write's relative target is resolved against the command's own
   `cd`, never the session cwd cd-guard keeps (claude-setup `hooks/lib/review-journal.sh`, `test_review_journal`).
4. **worker-on-exhausted-account**: fixed. `worker-run` claims a brief-named account (`test_worker_run_pool`).
5. **night-debt-passes-not-capped**: kept. The extra rounds came from the fit-round anchor bug, which is
   reverted. `debt-<n>` on resume is documented.
6. **shared-ledger-landing-conflicts**: fixed half. The replay pin derives from the ledger rows
   (`test_harness_doctor`). No merge driver, because it needs per-clone git config. Same cause:
   `harness-branches-conflict-on-shared-files`.
7. **limit-reset-no-auto-resume**: fixed. A week at its wall arms the timer for the weekly reset
   (`bin/claude-resume-timer`, `test_claude_resume_timer`).
8. **browser-worker-launch-failures**: proven. All 17 browser runs since f1a98bde exited 0.
9. **overbuilt-before-asking**, **reports-jargon-and-unverified-claims**, **memory-guard-lane-pause**: kept
   open, because no component is involved. Only the owner can dismiss them.
