# Hand-off: hook floors, cut the dearest hooks one at a time

Status: settled 20261006T233611Z-7777: a fix with `in` null holds from its landing (share/fix_commit.py `fix_held_from`): absent from main it regresses and proves nothing, so a night close reads it fixed-pending

Rows `floor-bash-other-hooks`, `floor-edit-hooks`, `floor:event:*`, `floor:tool`, `floor:read`. Egor 2026-10-05:
no dispatcher (weigh one only from 2026-10-05-harness-time-budget.md); cut the dearest hooks one at a time.

Cut: review-bench `bin/review-owner-gate.sh` (no `review-bench` in the command), claude-setup
`hooks/report-flush.sh` (nothing pending for the payload session or `_orphan`). The setters
(review-flow-gate, commit-journal, edit-conflict-notice, instruction-watch, stop-dispatch,
context-nudge) are the hooks area's rows.
