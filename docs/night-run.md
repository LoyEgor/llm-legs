# Night run

Status: design, being built (2026-09-30). Owner: the «Updater doctor» chat.

## Why
Egor (2026-09-30) wants one button pressed before sleep. Behind it, every doctor fixer, every
vendor-release integration and the cleanup sweep run on their own. By morning everything is
reviewed, committed and pushed in the four sweep repositories (`~/.claude/sweep-repos`).

The whole wall clock stays short: about 3 hours, never a 12-hour chain. Chats never disturb each
other. The morning report is trusted without reading chats.

This design folds in two frontier hunts (runs 20260929T225123Z-3e30191 and 20260929T225224Z-1baa277):
- night chats that stop on a question and sit idle;
- one sweep after the slowest fixer;
- pours into the live main checkout;
- account pile-up;
- racing run records;
- a hung job with nothing to stop it;
- a report that hides what did not land.

## Shape
1. **Button.**
   - Doctors menu → `Run everything now`, after a confirmation, →
     `bin/night-run start`; off while a night runs. It writes the night record and opens ONE
     orchestrator chat via `chat_open`. That chat takes an account with a claim, runs under
     `caffeinate -i -w <its pid>`, and starts with the prompt
     `сделай чистку — night run <night-id>`.
   - The sweep word arms the sweep span. The span carries the review grant, and commit and push, as
     a hand-typed «сделай чистку» does (claude-setup `hooks/lib/word-families.json` family `sweep`).
     The night-sweep skill reads the `night run <id>` marker and follows its **Night mode** section.
2. **Prep** (serial, a few minutes; the orchestrator does it):
   - `vendor-cli-update now --night` runs first and blocks, so CLI installs finish before any worker holds a CLI busy;
     it opens no integration chat, which would claim the events `request --night` hands to workers.
   - Refresh all three doctors so their documents are fresh.
   - `night-run base <id>` snapshots every sweep repository as it stands, uncommitted work
     included, into `refs/night/<id>/base`, touching neither index nor working tree. Every night
     worktree starts there: main carries days of uncommitted work, and a branch from HEAD would fix
     code that no longer exists. A branch merges only after its repository's press-time debt is
     committed, by `git rebase --onto main refs/night/<id>/base`.
   - `night-run job` records every expected job before dispatch, a `leftover` job among them for
     every leftover branch `night-run leftovers` lists, adopted into the night (see Leftovers).
3. **Dispatch.** Everything below starts in parallel at about t+10 min.
   - **Fixers.**
     - `doctor-fix launch <llm|harness|updater> --night <night-id>` makes one run per area that has
       problems. The areas are the doctor's own menu words, so the night's `<Doctor> fixer: <area>` row
       names a row of that doctor's menu:
       - the LLM doctor's block, or its health row (`debt`);
       - the Harness doctor's section;
       - else `doctor`, the doctor's own problems (the Updater's machinery: `pass-stale`, `cli-behind`, …),
         shown as a bare `<Doctor> fixer`. `share/doctor-areas.json` holds that word and the renamed old
         areas (`llm-health` → `debt`, `harness-self` and `updater-machinery` → `doctor`), so old runs
         keep their label; `tests/test_doctors_menu.sh` checks every label against the rendered menu.
     - Each run gets a worktree on branch `night/<night-id>/<run-id>` and a brief file.
     - The orchestrator starts each brief as a headless worker (`worker-run`, `--workdir` the
       worktree; account from `worker-pick`).
   - **Vendors.** `vendor-fingerprint request --night <night-id>` makes one event per vendor with a
     REAL waiting release (no manual full-checklist events at night). Each gets an updater fixer
     run (the printed ref), a worktree on `night/<night-id>/<vendor>`, the same branch's worktrees in
     review-bench and claude-setup as the brief's `ADD-DIR:` lines, and a brief. One headless worker
     per vendor.
   - **Existing debt.** The orchestrator runs the sweep's debt rounds (night-sweep step 3), each ONE
     chunked round across all sweep repositories, over the debt that already sat in main at press
     time. Workers never touch main, so this runs beside them.
4. **Per branch, as soon as its worker returns** (a completion notification, never polling):
   - The run closed: its close gate reran the doctor inside the worktree and passed.
   - One T2 bugs review of that branch.
   - The orchestrator reads the decision table itself and checks every non-`fixed` verdict. That is
     the second model on a fixer's self-clearing.
   - Findings are fixed by the SAME worker (RESUME) on the round's `review-bench fix` brief, whose
     `ROUND:` line folds its fixer rows; a fix made any other way leaves the round open, and
     `night-run job set … state=merged` refuses a job whose `review` round still has open findings
     until the round is fixed that way or closed `review-bench close <round> --nofix --reason '…'`.
   - The branch is rebased onto main's HEAD. The same worker resolves conflicts, since it knows its
     intent. Suites must pass.
   - Commit (one long line) and push.
   - One commit per branch is fine: commit count does not matter to Egor. Merges into main are
     serial and short; everything else is parallel.
5. **No deadline** (Egor, 2026-09-30: a 4 h deadline closed a night while a debt round was still
   running, and its findings sat unfixed until noon).
   - The orchestrator works until every job is `merged`, `nothing-to-do` or `blocked-on-egor`; a
     round that finishes late is fixed and landed like any other.
   - The only stop is for a hung job: `worker-run`'s watchdog ends a worker that shows no progress
     (`WORKER_RUN_IDLE_S`, 30 min; a 6 h wall ceiling behind it). The orchestrator then abandons its
     run (`doctor-fix abandon`) and records the job `left` with the watchdog's reason; its branch
     stays unmerged and is named in the report.
6. **Close.**
   - Rerun the three doctors. This settles the ledger's `fixed-pending` rows. Commit and push that
     bookkeeping as well, so nothing is dirty after the last push.
   - `night-run finish` writes the morning result, then `span-off`. It also removes every landed,
     clean, not live branch of the sweep repositories with its worktree (see Leftovers); it prints
     each live one `live <repo> <branch>: <why>` and each leftover `leftover <repo> <branch>: <why>`,
     records the leftovers under the night's `leftovers`, and `night-run report` lists them as
     unfinished work.

## Isolation rules
- At night a worker never writes the main checkout.
  - There is no pour step: `docs/doctor-fix.md` and `docs/vendor-release.md` each get a Night section
    that replaces the pour with a commit on the worker's own branch.
  - A second repository gets its own worktree on the same branch name.
- Tests in a worktree run against the job's own worktree set: `share/run-suites.sh` exports a
  sibling repository's worktree on the same branch, else that repository's main checkout (a job that
  did not touch it tests against main, which is its true base).
- Hammerspoon's live config reload ignores `.claude/worktrees/`, so a worktree `.lua` never loads live.
- Accounts: `chat_open` and every worker take a `worker-pick` claim, so parallel launches spread.
- Run records: every read-modify-write takes a lock, and run ids are unique under parallel launch.
- The whole night runs under `caffeinate -i`.

## Morning record
`~/.cache/doctors/nights/<night-id>.json`:
- `id`, `started_at`, `finished_at`, the orchestrator's `session` and, once resumed, the earlier
  ones in `previous_sessions`;
- `doctors_before` and `doctors_after` (problem counts), and `doctor_states_before`/`doctor_states_after`:
  per doctor the problems of its `latest.json` by ledger state, `proved` (a harness fix proven,
  `fixed · E events since · 0 matched`), `pending` (`fixed-pending` or rule `fix-proof`), `open`,
  `new`, `regressed`. `report` prints one line per doctor,
  `harness 35 → 38 · proved 4 · pending 18 · new 16 · regressed 5`; the menu's Last night shows only the jobs;
- `jobs[]`, each with:
  - `kind` (fixer, vendor, debt or leftover) and `ref` (run id, event id, review round or
    `leftover-<slug>`); a leftover job also carries `adopted[]` ({repo, branch, worktree, tip,
    night_worktree}), where its branch came from;
  - `state`: `merged`, `left` (with a reason), `failed-launch`, `blocked-on-egor` or `nothing-to-do`;
  - `branch`, `review` (run id), `commits[]` ({repo, hash}) and `pushed` (bool, as verified against
    the remote).

Jobs start `pending`; `finish` turns any still `pending` into `left`. `pushed` is set only after
the commits are verified on the remote (`ls-remote`, the remote head fetched when it is missing
locally, plus ancestry); a changed `commits` list clears it until `pushed=true` checks again. A chat that fails to open finishes
the night at once with a note: red in the menu, never blocking a retry.

A night not finished reads `running` while a process carrying its orchestrator's `--session-id`
lives, and `UNFINISHED` (red) once that chat is gone. Before the session is recorded the night
carries `opener`, the pid of the `start` opening its chat, and reads `running` only while that
process lives, so a start killed mid-open never blocks the next one. Only a running night refuses
`start`.

## Continue and Cleanup
- `night-run start --resume <id> [--job <ref>]` reopens the SAME night for a new orchestrator
  (prompt `сделай чистку — night run <id> resume`): `finished_at`, `doctors_after` and `doctor_states_after` go null, the old
  `session` is appended to `previous_sessions`, and the unfinished (`left`, `pending`) jobs, or the one
  `--job` names, go back to `pending` with their reasons kept. Without `--job` a `debt-<n>` job is
  added when no debt job is pending. The review-flow gate needs no change: it reads the night's
  `finished_at` and live `session`, so resumed workers commit on their `night/<id>/…` branches again.
- `night-run start --cleanup` opens a new night with the prompt `сделай чистку — night run <id>
  cleanup`: the orchestrator lands the finished night branches and every leftover, and runs the debt
  round, no fixers, no updates.
- The Doctors menu: `Cleanup now` above `Run everything`, behind
  the same Cancel-first confirmation and off while a night runs; under the last night, while it does
  not run, each unfinished job gets `Continue this job` one level down, and one item `Continue
  unfinished (N jobs) + cleanup` resumes them all.

## Leftovers
Egor (2026-10-01): in the sweep repositories no branch or worktree but main outlives the work going on
right now; a kept worktree once held a review fix that then got lost from every branch.
`night-run leftovers [--json]` lists every non-main branch and worktree with its repository, worktree,
landed (in main, or a night branch still at its night's base), ahead/behind main, dirty count and a
state, the one predicate `finish` prunes by:
- `live`, never touched: the main checkout, a locked worktree, a process with its cwd inside, a branch
  of a running night, or a non-night branch whose newest branch-reflog entry or dirty file is under
  6 h old. A chat at work moves its branch (create, commit, rebase) or leaves files dirty, so a fresh
  worktree with no commit yet is live from its creation.
- `landed`: landed, clean, not live; `finish` removes its worktree and deletes the branch.
- `leftover`: everything else (unlanded commits or uncommitted files). It is unfinished work and goes
  into main as a night job. `night-run job <id> add leftover <branch>` adopts it into the night's own
  namespace, where the review-flow gate lets workers commit, in every sweep repository where that
  branch is a leftover (one job; refused if it is live in any of them, or landed, or unknown). Per
  repository: uncommitted files (`.gitignore` honoured, secret names and big blobs dropped as for the
  base) become one commit `Leftover WIP from <branch>, adopted by night <id>` on the branch;
  `night/<id>/leftover-<slug>` (`/` → `-`) is made at its tip with its worktree at
  `<repo>/.claude/worktrees/night-<id>-leftover-<slug>`, like every night worktree; then the old
  worktree and branch are removed. It needs `night-run base <id>` first. The job's ref is
  `leftover-<slug>`. From there it is a night branch like any other, through the per-branch flow;
  its worker first runs `git rebase refs/night/<id>/base`, so the review range and the later
  `--onto` hold only its own change. A landing that fails stays `left`, and a later Cleanup takes it
  like any other night branch.

`night-run report [<id>]` prints it narrowly: one line per job, then the totals. A job with commits
shows `code +A/-R`: lines its commits add and remove, test paths (`tests/`, `test_*`) left out;
`code ?` when a commit cannot be read. Information only: no threshold.

The Doctors menu shows the last night on one row from `night-run latest --menu`, such as
`Last night 30 Sep: 11 of 13 · 2 unfinished`; its submenu lists every job, done or unfinished, with
the reason in a few words and the whole reason one level down. The state is the color, not words: a
job done and pushed is a dim name alone (one with nothing to do keeps those words), one still owing work (unfinished, in
progress, not pushed yet) is plain with its word, red only where Egor is needed: a job blocked on him
or a failed launch. Output: a title line `text\ttone\trunning\tid`, then one
`text\ttone\treason\tref\tkind\tresumable` line per job (`tone` 0 dim, 2 plain, 1 red;
`resumable` 1 for an unfinished job of a night that does not run).

## Day Fix button
Unchanged. It opens an interactive chat on one doctor, and that chat pours into main uncommitted.
The night brief and the day chat follow the same procedure file; only the last step differs.
