# Fix orchestrator

One chat dispatches a launch's fixer runs and lands each branch, day and night. Its input is
`<ref>\t<brief>\t<worktree>` lines (ref = a `doctor-fix` run; a vendor's run holds its events): by day the
file `doctor-fix launch` or `vendor-fingerprint request` opened this chat on, at night the night-sweep skill's
jobs (`night-run job`).

## Dispatch, all at once

`worker-pick`, then per line its START line with the brief file and `--workdir <worktree>` (a `MODEL: sonnet`
brief: `worker-run start claudeb --account $(worker-pick --account claudeb)`), and a background `worker-run
wait`; a report's `ESCALATE-BRIEF:` file starts again on the plain START line. A brief whose `ROUND:` is not `none` waits for its speed-lens round (a background `review-bench
wait`). Never poll.

A vendor's run also gets, per event, its blind cross-check (`docs/vendor-release.md` step 4): `worker-run
start <other vendor> --role research --web-search`, account from `worker-pick --account <vendor> --role
research`, never Gemini Flash; its brief names only the product and version range and forbids reading
the repositories.

## Per branch, when its worker completes

1. `doctor-fix show <ref>` reads closed and its close gate passed.
2. Check every non-`fixed` verdict of its decision table yourself, a vendor's run against its blind list
   too; no per-branch review.
3. What you find goes to the SAME worker (`RESUME <session>:`, the brief's `ADD-DIR:` lines under it); it
   resolves conflicts and gets suites green; at night, after that repository's press-time push, it first
   rebases as step 4 does.
4. `git -C <worktree> rebase main` (night: `--onto main refs/night/<id>/base`), then in the worktree `tests/run-all
   $(tests/affected $(git diff --name-only main...HEAD))`; green: in the main checkout `git merge --ff-only
   <branch>` (hooks push), `git worktree remove <worktree>`, `git branch -D <branch>`, `git push origin --delete
   <branch>`, the same per `ADD-DIR:` repository (one without commits loses only its worktree and branch), by day
   `git update-ref -d refs/doctor-fix/<ref>/base`; a conflict or red goes to step 3.
5. A worker the watchdog killed (`KILLED: idle|silent|deadline`): `doctor-fix abandon <ref>`, its branch
   unlanded.

Report per ref: landed (repo@hash) or why not, every handoff and `blocked-on-egor` line.
