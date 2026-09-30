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
- no deadline for the sweep;
- a report that hides what did not land.

## Shape
1. **Button.**
   - Doctors menu → `Night run` → `bin/night-run start`. It writes the night record and opens ONE
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
   - `night-run job` records every expected job before dispatch.
3. **Dispatch.** Everything below starts in parallel at about t+10 min.
   - **Fixers.**
     - `doctor-fix launch <llm|harness|updater> --night <night-id>` makes one run per area that has
       problems. The areas are:
       - the LLM doctor's block, or `health`;
       - the Harness doctor's section;
       - for the Updater, its own machinery problems (`pass-stale`, `cli-behind`, …).
     - Each run gets a worktree on branch `night/<night-id>/<run-id>` and a brief file.
     - The orchestrator starts each brief as a headless worker (`worker-run`, `--workdir` the
       worktree; account from `worker-pick`).
   - **Vendors.** `vendor-fingerprint request --night <night-id>` makes one event per vendor with a
     REAL waiting release (no manual full-checklist events at night). Each gets a worktree on
     `night/<night-id>/<vendor>` and a brief. One headless worker per vendor.
   - **Existing debt.** The orchestrator runs the sweep's debt rounds (night-sweep step 3) over the
     debt that already sat in main at press time. Workers never touch main, so this runs beside them.
4. **Per branch, as soon as its worker returns** (a completion notification, never polling):
   - The run closed, and its close gate passed inside the worktree against a run-local doctor
     document.
   - One T2 bugs review of that branch.
   - The orchestrator reads the decision table itself and checks every non-`fixed` verdict. That is
     the second model on a fixer's self-clearing.
   - Findings are fixed by the SAME worker (RESUME).
   - The branch is rebased onto main's HEAD. The same worker resolves conflicts, since it knows its
     intent. Suites must pass.
   - Commit (one long line) and push.
   - One commit per branch is fine: commit count does not matter to Egor. Merges into main are
     serial and short; everything else is parallel.
5. **Deadline.**
   - The night record carries `deadline_at` (default start + 4 h).
   - At the deadline the orchestrator marks unfinished runs abandoned (`doctor-fix abandon`) and
     stops their workers. Their branches stay unmerged and are named in the report.
   - The debt recount loop also stops at the deadline, and what is left is named.
6. **Close.**
   - Rerun the three doctors. This settles the ledger's `fixed-pending` rows. Commit and push that
     bookkeeping as well, so nothing is dirty after the last push.
   - `night-run finish` writes the morning result, then `span-off`.

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
- `id`, `started_at`, `deadline_at`, `finished_at`, and the orchestrator's `session`;
- `doctors_before` and `doctors_after` (problem counts);
- `jobs[]`, each with:
  - `kind` (fixer, vendor or debt) and `ref` (run id, event id or review round);
  - `state`: `merged`, `left` (with a reason), `failed-launch`, `blocked-on-egor` or `nothing-to-do`;
  - `branch`, `review` (run id), `commits[]` ({repo, hash}) and `pushed` (bool, as verified against
    the remote).

Jobs start `pending`; `finish` turns any still `pending` into `left`. `pushed` is set only after
the commits are verified on the remote (`ls-remote` plus ancestry). A chat that fails to open finishes
the night at once with a note: red in the menu, never blocking a retry.

`night-run report [<id>]` prints it narrowly: one line per job, then the totals.

The Doctors menu shows the last night on one row, such as `Night: 7 merged · 1 left · pushed`. The
row is red when anything was left, failed or is blocked on Egor.

## Day Fix button
Unchanged. It opens an interactive chat on one doctor, and that chat pours into main uncommitted.
The night brief and the day chat follow the same procedure file; only the last step differs.
