# Hand-off: session-trash's delayed purge carries the worker's run id

Status: open

To: the next night, claude-setup. Row `worker-orphans-detached-on-purpose`. Written by night fixer
harness-wait-classes-20261006T234313Z-2366.

worker-run ends every process left holding `WORKER_RUN_ID=<run>` at the run's end (`end_run_orphans`,
llm-legs@8a5f5a80). claude-setup `hooks/session-trash.sh` `hook_end` detaches
`nohup "$0" __purge-delayed` from a worker's SessionEnd, so it inherits the id and is TERMed ~1 s
later, inside its `sleep 2`: the purge and both sweeps never run for worker sessions. 2026-10-06/07:
375 of 542 recorded orphans are this job and its `sleep 2`/`sleep 8`.

Fix: `nohup env -u WORKER_RUN_ID "$0" __purge-delayed …` on both lines (580, 582), as llm-legs
`pack_loose_objects` now does; a test that the detached job's `ps -E` environment lacks the id.
