# Hand-off: open hook-cost rows after the 2026-10-04 night fixer

Status: done 2026-10-04 — hook-grows-repos-worker-launch-gate, hook-grows-size-worker-launch-gate, hook-grows-size-instruction-watch, hook-grows-repos-english-gate, hook-full-work-worker-tag-hook, hook-p50-worker-limit-gate, hook-every-call-commit-journal, hook-sync-commit-journal, hook-sync-review-flow-gate, hook-every-call-instruction-watch, hook-sync-instruction-watch-check, hook-sync-instruction-watch-baseline, hook-sync-edit-conflict-notice, hook-p50-commit-journal, hook-p50-review-flow-gate, hook-p50-edit-conflict-notice, hook-p50-instruction-watch-baseline

Settled by «Harness Doctor», 2026-10-04. It replaces the hand-off written by night fixer run
`harness-hooks-20261004T013933Z-5514`.

1. hook_p50 under load: a `hook_p50` judged per load band, or on hook CPU, is a change to
   bin/harness-doctor. It is proposed to that file's owner. The rows stay open meanwhile.
2. Five dismissals made `not-a-bug`. Each row's note gives the file:line evidence.
3. Floors: the owner's decision is to cut and keep the limit. The cut for each hook is in its row's
   note, for the night fixers. worker-pick `--account <vendor>` now reads only that vendor's claims,
   walls, pins and pools. Test: test_worker_pick.sh, red on the old code. Row
   `hook-p50-worker-limit-gate` is fixed-pending.
