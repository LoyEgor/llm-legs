# Fix orchestrator

One chat dispatches a launch's fixer runs and lands each branch, by day and at night alike. Its input is
`<ref>\t<brief>\t<worktree>` lines (ref = a `doctor-fix` run; a vendor's run holds its events): by day the
file `doctor-fix launch` or `vendor-fingerprint request` opened this chat on, at night what the night-sweep
skill records as jobs first (`night-run job`, its only addition).

## Dispatch, all at once

`worker-pick`, then one background relay worker per line: the brief file as its brief, `--workdir
<worktree>`. A brief whose `ROUND:` is not `none` waits for that speed-lens round: one `review-waiter`
per round, the brief dispatched on its return. Never poll.

## Per branch, on its worker's completion notification

1. `doctor-fix show <ref>` reads closed and its close gate passed.
2. Check every non-`fixed` verdict of its decision table yourself; no per-branch review.
3. What you find goes to the SAME worker (`RESUME <session>:`), the brief's `ADD-DIR:` lines copied right
   under it; it resolves conflicts and gets suites green in its worktree. At night, once that repository's
   press-time tree is pushed, it first runs `git rebase --onto main refs/night/<id>/base`.
4. `bin/worktree land <worktree> [--review <round>] [--suites-passed]`; a refusal goes to step 3.
5. A worker the `worker-run` watchdog killed (`KILLED: idle|silent|deadline`) is hung: `doctor-fix abandon
   <ref>`; its branch stays unlanded.

Report per ref: landed (repo@hash) or why not, every handoff and `blocked-on-egor` line.
