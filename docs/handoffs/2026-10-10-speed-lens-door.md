# doctor-fix's speed lens never launches: the review door refuses scripts

Status: open — To: Harness Doctor

Night 20261010T031219Z-4c4e: `doctor-fix launch all --night R` printed `gets no speed lens: review-bench: a
review launch inside Claude Code runs only as the plain Bash call the review door let through` for all 39
Speed runs, so every brief got `ROUND: none`. `speed_lens` (bin/doctor-fix, llm-legs@390d027d, 2026-10-08)
calls `review-bench review` from inside the script; `guard_review_door` (review-bench share/rbench/cli.py,
since 8dbea42) only accepts the nonce claude-setup `hooks/review-flow-gate.sh` stamps on a Bash call that
itself spells the launches, so the lens has never run inside a chat.

Fix by doctrine, no door bypass: `doctor-fix launch` writes each lens launch as a ready
`review-bench review …` line (key, run id) and leaves its brief waiting; the orchestrator runs them as ONE
Bash call (the door stamps as many uses as the call spells), then `doctor-fix lens-rounds` records the
round ids into the briefs' `ROUND:`. Or drop the lens: 39 T2 rounds a night against the night spend goal.
