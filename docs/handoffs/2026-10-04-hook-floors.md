# Hand-off: hook floors stay over their limits on the per-call bash fan-out

Status: trade — To: Egor

To: Egor. Ledger rows `floor-bash-other-hooks`, `floor-edit-hooks`, `floor:event:SessionStart`,
`floor:event:Stop`, `floor:tool` (each note has the 2026-10-04 numbers).

Cost: one dispatcher per hook side, as stop-dispatch did for Stop. It means rewriting the hook registrations in the unversioned `~/.claude/settings.json` plus a dispatcher in claude-setup, ~200 lines. Each hook also loses its own timeout and isolation: one slow or crashing hook then delays or breaks every hook on that side.
Loss: with both setters cut, a non-trivial Bash call still starts 18 PreToolUse and 10 PostToolUse processes. At load ~280 that keeps bash:other at 0.5-1 s or more over its 500 ms limit (467-1010 ms on 10-03 at CPU busy 0.9-1.0). Edit and SessionStart stay over too.
Recommendation: keep the per-hook registrations and the limits. Let night fixers cut the named setters (the cut rows in the ledger). Revisit the dispatcher only if the floors are still over on a quiet machine (load < 20).
