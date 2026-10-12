# Speed-gate refusals read as unclassified worker failures

Status: open — To: LLM Doctor owner (ledger W11)

`night-run speed-gate` refusals (worker-run exit 4, no CLI start, job left pending) read `unclassified`.
Holders: a live worker of the same job in the sibling repository's worktree (0312, the intended catch); a
`session-trash.sh __purge-delayed` (58a4); the launching chat's own background shell (5e93). The 6867
caffeinate was the run's own supervisor's, fixed 2026-10-12 (ledger note).

Decide:
1. Whether a refusal before any CLI start is a failure leg at all (no account spent; prelaunch `EFFORT_REFUSED`
   reads `off`). Loosening is yours, not a fixer's.
2. Whether `cwd_holders` in the gate should skip the launcher chat's own process tree (the supervisor is
   detached, so the self-ancestry skip never covers it) and non-writers (session-trash purges).
