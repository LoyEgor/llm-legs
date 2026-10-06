# Hand-off: hook floors, cut the dearest hooks one at a time

Status: settled 20261006T032009Z-f253: review-owner-gate and report-flush exit on builtins on a plain call (84→15, 69→9 ms); setters stay the hooks area's

Ledger rows `floor-bash-other-hooks`, `floor-edit-hooks`, `floor:event:SessionStart`, `floor:event:Stop`,
`floor:tool`, `floor:read`. Decided 2026-10-05 (Egor): no dispatcher; night fixers cut the dearest hooks one
at a time, the limits stay. Weigh a dispatcher again only from the harness time budget
(2026-10-05-harness-time-budget.md), never from per-call ms.

Cut: review-bench `bin/review-owner-gate.sh` (no `review-bench` in the command), claude-setup
`hooks/report-flush.sh` (nothing pending for the payload session or `_orphan`). The setters
(review-flow-gate, commit-journal, edit-conflict-notice, instruction-watch, stop-dispatch,
context-nudge) are the hooks area's rows.
