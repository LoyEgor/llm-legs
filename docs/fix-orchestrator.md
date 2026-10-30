# Fix orchestrator

One chat dispatches a launch's fixer runs and lands each branch, day and night. Its input is
`<ref>\t<brief>\t<worktree>` lines (ref = a `doctor-fix` run; a vendor's run holds its events): by day the
file `vendor-fingerprint request` opened this chat on, at night the night-sweep skill's jobs (`night-run job`).

## Dispatch, all at once

`worker-pick`, then per line its START line with the brief file and `--workdir <worktree>` as a background
Bash (a `MODEL: sonnet` brief: `worker-run run claudeb`); a report's `ESCALATE-BRIEF:` file starts again on the plain START line. `ROUND: pending` (worker-run
refuses it): run every line `doctor-fix lens-lines <ref>...` prints in ONE Bash call first; a brief naming
a round waits for it (a background `review-bench wait`). Never poll.

A vendor's run also gets, per event, its blind cross-check (`docs/vendor-release.md` step 4): `worker-run
start <other vendor> --role research --web-search`, account from `worker-pick --account <vendor> --role
research`, never Gemini Flash; its brief names only the product and version range and forbids reading
the repositories.

## Per branch, serially when its worker completes

1. `doctor-fix show <ref>` reads closed. Its close gate does not prove suites green. By day, require all branch covering suites (including the slow layer) green on the worker's final commit in every worktree (report and run-suites journal `head`); missing proof goes to step 3. A `night/…` branch's worker runs none: `land` runs them.
2. Check every non-`fixed` verdict of its decision table yourself, a vendor's run against its blind list
   too; no per-branch review.
3. What you find goes to the SAME worker (`RESUME <session>:`, the brief's `ADD-DIR:` lines under it); it
   resolves a conflict by rebasing onto main and fixes a red suite; it never lands.
4. Land one branch at a time: `bin/land <branch>` (Egor 2026-10-30), never a script of your own. A `night/…`
   branch lands in every sweep repository holding it; another names each `ADD-DIR:` repository with
   `--repo <dir>`. It rebases past the press snapshot, runs in each worktree a night branch's covering suites
   or otherwise only those main's new commits share with the branch, reruns a red one once alone (green
   prints `flaky`), fast-forwards main to the tested commit and, once every repository has, drops worktrees
   and branch; main moving under it repeats its pass. Exit 0: its `commits=` line is the merged line's. Exit 1
   (conflict, red twice, uncommitted work, a selection error): step 3. Exit 3 (another land holds the branch,
   the main checkout refuses, main kept moving): its line names what to wait for, the holder's
   `bin/wait-until pid <n>` to run as a background Bash, an index.lock's age, the branch the main checkout
   is on; land again once that clears, never on a timer. A `commits=` line after exit 1 or 3 is what landed
   before the stop; the rerun reports it again. A rerun after a killed land resumes it.
5. A worker the watchdog killed (`KILLED: idle|silent|deadline`): `doctor-fix abandon <ref>`, its branch
   unlanded.

Report per ref: landed (repo@hash) or why not, every handoff and `blocked-on-egor` line.
