# Log audit of night 20261006T233611Z-7777 (run harness-doctor-20261007T214015Z-24b7)

Status: settled 20261009T023738Z-817e: 1 LC_ALL=C awks + NUL strip in jq, 2 `worker-run stop` named by the Stop ask (relays retired), 3 cause gone since 06c1915c (each job's worktree removed at landing), 4 stays the owner's dismissal

Quotes: `~/.cache/doctors/log-audit/runs/20261006T233611Z-7777/chunk-*.md`.

Items 1-3 (hook-awk-multibyte-failure, relay-stop-leaves-worker-running, debt-scope-double-count) are settled above.

4. Ruled out as harness bugs, dismissal proposed to the owner:
   - **night-worker-queue-wait**: the `night-workers` wait class journals every slot wait, and slots are paced by
     load as settled in `2026-10-06-speed-floors.md`.
   - **detached-chain-dies-with-builder**: worker-run ends every process carrying the run's `WORKER_RUN_ID` at run end
     (8a5f5a80), as designed. For the chat «Vector Magic macOS ARM migration»: a builder brief starts a chain meant to
     outlive the builder as `env -u WORKER_RUN_ID nohup … &`.
