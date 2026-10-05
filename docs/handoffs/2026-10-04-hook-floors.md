# Hand-off: hook floors, cut the dearest hooks one at a time

Status: open — To: next night (harness-hook-waits)

Ledger rows `floor-bash-other-hooks`, `floor-edit-hooks`, `floor:event:SessionStart`, `floor:event:Stop`,
`floor:tool`, `floor:read`. Decided 2026-10-05 (Egor): no dispatcher; night fixers cut the dearest hooks one
at a time, the limits stay. Weigh a dispatcher again only from the harness time budget
(2026-10-05-harness-time-budget.md), never from per-call ms.

Open cuts (CPU on a plain call, scratch HOME, 2026-10-05):
1. review-bench `bin/review-owner-gate.sh`, 44 ms on every Bash call: it runs 2 jq and sources review-journal
   before it knows the call names no review-bench. Leave on builtins first, as commit-report does: the
   command with line continuations, quotes and backslashes dropped must contain `review-bench`.
2. claude-setup `hooks/report-flush.sh`, 46 ms on every tool call: report-bus starts (two bash, two jq) with
   nothing pending. A builtin glob over the report store's `*/pending/*.txt` decides first.
3. The setters themselves (review-flow-gate, commit-journal, edit-conflict-notice, instruction-watch,
   stop-dispatch, context-nudge) are the hooks area's rows; this area takes them only when no hooks run does.
