# Speed-gate refusals read as unclassified worker failures

Status: open — To: LLM Doctor owner (ledger W11)

Night 20261010T031219Z-4c4e, fixer llm-workers. Three worker legs on 2026-10-09 (`unclassified · exit 4`) were
`night-run speed-gate` refusals: worker-run took the slot, the gate found a process standing in the job's night
worktree, returned 4 before any CLI start, and the job stayed pending. Holders seen: another live worker of the
same job in the sibling repository's worktree (0312); `session-trash.sh __purge-delayed` with `sleep 8` (58a4);
the launching orchestrator chat's own background shell (5e93, holder's shell path names its session); on
2026-10-10 `caffeinate -i -w <pid>` (6867).

Decide:
1. Whether a refusal before any CLI start is a failure leg at all (no account spent; prelaunch `EFFORT_REFUSED`
   reads `off`). Loosening is yours, not a fixer's.
2. Whether `cwd_holders` in the gate should skip the launcher chat's own process tree (the supervisor is detached,
   so the self-ancestry skip never covers it) and non-writers (session-trash purges, caffeinate).
