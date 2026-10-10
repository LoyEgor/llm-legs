# Hand-off: ask-run-unfinished duplicates the run backstop; the night sweep chat's unread words

Status: settled 20261010T031219Z-4c4e: ask-run-unfinished keeps only dead and done-never-read reviews, a live run is the backstop's alone (its --unowned mode gone too), inside a span ask-span-drill's one nudge stands in; word-miss-night-sweep-no-reading dismissed, the words were night-run's own message

To: next night (item 1, claude-setup stop hooks); the chat «Harness Doctor» (item 2). From night fixer
harness-stop-hooks-20261009T024811Z-29b3, which had no claude-setup worktree.

1. Ledger `hook-error-ask-run-unfinished-stall`. claude-setup `hooks/stop.d/ask-run-unfinished.sh`
   asks for the same live runs and reviews as llm-legs `bin/worker-run-backstop.sh`, which runs
   first, is never deferred and since llm-legs@1adcb7bb also owns a run named by any waiting command
   line under the chat; on 2026-10-09T00:45:16Z/2ddedf36 both asked for one run. Delete the run loop,
   the `live` review branch and what serves only them (`waits` ps scan, `owned`, `starter_alive`,
   `asked_once`); keep dead and done-never-read reviews. Both exit 124 were in them: the night chat's
   18 live runs at load 255 cost a dozen forks each right after the backstop checked them. Decide:
   the backstop never holds inside a span; the ask asked there once.
2. Ledger `word-miss-night-sweep-no-reading`. The night sweep chat acted on `сделай чистку — night
   run <id>` without its ⚡ reading lines (the 7 nights before wrote them); ask-word-reading.sh, deferred
   while busy, asked at 03:45:38Z and the late reading settled it, an hour after the doctor counted it.
   Proposed: dismiss as a model miss, or count a busy chat's row only after its deferred ask has run.
