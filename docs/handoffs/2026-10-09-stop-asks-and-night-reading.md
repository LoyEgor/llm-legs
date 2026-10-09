# Hand-off: ask-run-unfinished duplicates the run backstop; the night sweep chat's unread words

Status: open

To: next night (item 1, claude-setup stop hooks); the chat «Harness Doctor» (item 2). From night fixer
harness-stop-hooks-20261009T024811Z-29b3, which had no claude-setup worktree.

1. Ledger `hook-error-ask-run-unfinished-stall`. claude-setup `hooks/stop.d/ask-run-unfinished.sh`
   asks for the same live runs and reviews as llm-legs `bin/worker-run-backstop.sh`, which runs
   first, is never deferred and since llm-legs@1adcb7bb also owns a run named by any waiting command
   line under the chat; on 2026-10-09T00:45:16Z/2ddedf36 both asked for one run. Delete the run loop,
   the `live` review branch and what serves only them (`waits` ps scan, `owned`, `starter_alive`,
   `asked_once`); keep dead and done-never-read reviews. The scan sat in the one exit 124 (5.02 s
   wall for 0.28 s CPU). Decide: the backstop never holds inside a span; the ask asked there once.
2. Ledger `word-miss-night-sweep-no-reading`. The night sweep chat acted on `сделай чистку — night
   run <id>` without its ⚡ reading lines (the 7 nights before wrote them), and ask-word-reading.sh is
   skipped-busy at every stop of a chat busy all night. Proposed: dismiss as a model miss, or count a
   busy chat's row only after its deferred ask has run.
