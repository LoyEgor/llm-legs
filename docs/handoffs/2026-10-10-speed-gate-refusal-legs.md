# Speed-gate refusals read as unclassified worker failures

Status: settled 20261012T005404Z-e2f7: a gate refusal (no CLI start, no account) reads off · refused · night gate like a prelaunch refusal; the gate skips the launching chat's own tree (worker-run records its claude pid for a night worktree); 6867's caffeinate waited on that run's OWN supervisor and now starts from /, as do session-trash's detached tails (58a4); 0312 stays the intended catch

`night-run speed-gate` refusals (worker-run exit 4, no CLI start, job left pending) read `unclassified`.
Holders: a live worker of the same job in the sibling repository's worktree (0312, the intended catch); a
`session-trash.sh __purge-delayed` (58a4); the launching chat's own background shell (5e93). The 6867
caffeinate was the run's own supervisor's, fixed 2026-10-12 (ledger note).

Decide:
1. Whether a refusal before any CLI start is a failure leg at all (no account spent; prelaunch `EFFORT_REFUSED`
   reads `off`). Loosening is yours, not a fixer's.
2. Whether `cwd_holders` in the gate should skip the launcher chat's own process tree (the supervisor is
   detached, so the self-ancestry skip never covers it) and non-writers (session-trash purges).
