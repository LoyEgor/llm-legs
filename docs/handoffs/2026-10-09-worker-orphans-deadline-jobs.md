# worker_orphans counts jobs a deadline cut, not leaks

Status: open — To: Harness Doctor

From night 20261009T023738Z-817e run harness-wait-classes; row `worker-orphans-detached-on-purpose` (now open).
The 26 orphans of 2026-10-09 are logo-vectorizer-bench builders' `nohup` python jobs in three runs the 6 h deadline
killed; they ended with the run, so nothing was left behind and worker-run has nothing more to fix.
Its on-purpose detaches (session-trash purge, worker-run pack) are zero since 2026-10-07.

Proposal, a judge change for the owner: `worker_orphans_line` counts only runs that ended on their own (`reason`
done or failed, not deadline, idle, silent or signal), or one verdict per command family as blind spot
`worker-orphans-unclassified` asks. Either clears today's red and keeps the done-run chains, which
`worker-run report` now names as `ENDED:` (llm-legs@6431047f).
