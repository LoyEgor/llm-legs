# Hand-off: hook floors stay over their limits on the per-call bash fan-out

Status: decided 2026-10-05 (Egor) — To: Harness Doctor

To: Egor. Ledger rows `floor-bash-other-hooks`, `floor-edit-hooks`, `floor:event:SessionStart`,
`floor:event:Stop`, `floor:tool` (each note has the 2026-10-04 numbers).

Cost: one dispatcher per hook side, as stop-dispatch did for Stop. It means rewriting the hook registrations in the unversioned `~/.claude/settings.json` plus a dispatcher in claude-setup, ~200 lines. Each hook also loses its own timeout and isolation: one slow or crashing hook then delays or breaks every hook on that side.
Loss: with both setters cut, a non-trivial Bash call still starts 18 PreToolUse and 10 PostToolUse processes. At load ~280 that keeps bash:other at 0.5-1 s or more over its 500 ms limit (467-1010 ms on 10-03 at CPU busy 0.9-1.0). Edit and SessionStart stay over too.
Recommendation: keep the per-hook registrations and the limits. Let night fixers cut the named setters (the cut rows in the ledger). Revisit the dispatcher only if the floors are still over on a quiet machine (load < 20).

## Decided 2026-10-05 (Egor)
No dispatcher now. Night fixers cut the dearest hooks one at a time (review-flow-gate before, commit-journal after a
Bash call; edit-conflict-notice on Edit/Write). Scale on 2026-10-05 01:30, all chats: about 600 Bash calls/h at p50
1.0 s, 90 Edit/Write at 1.9 s, the other events 0.2-1.5 s — about 14 min of hook wait per hour summed over chats,
about 5 % of each chat's turn time. A tax, not the night's bottleneck (that was the suite-slot queue, cut 10-04).
Decide on the dispatcher again from the harness time budget (2026-10-05-harness-time-budget.md), not from per-call ms.
