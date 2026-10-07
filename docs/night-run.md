# Night run

Status: design, being built (2026-09-30). Owner: the «Updater doctor» chat.

## Why
Egor (2026-09-30) wants one button pressed before sleep. Behind it, every doctor fixer, every
vendor-release integration and the cleanup sweep run on their own. By morning everything is
reviewed, committed and pushed in the four sweep repositories (`~/.claude/sweep-repos`).

The whole wall clock stays short: about 3 hours, never a 12-hour chain. The morning report is trusted without reading chats.

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
   - Refresh all five doctors so their documents are fresh. The Code doctor's refresh is
     `bin/code-doctor refresh` (index, journal rollup, candidates), then
     `bin/code-doctor judge --night <night-id>`: worker-run judgments of the waiting candidates,
     stopped by its token and wall budget (`BUDGET`), so a Code fixer only ever sees judged problems.
   - `night-run base <id>` snapshots every sweep repository as it stands, uncommitted work
     included, into `refs/night/<id>/base`, touching neither index nor working tree. Every night
     worktree starts there: main carries days of uncommitted work, and a branch from HEAD would fix
     code that no longer exists. A branch merges only after its repository's press-time debt is
     committed, by `git rebase --onto main refs/night/<id>/base`.
   - `night-run job` records every expected job before dispatch, a `leftover` job among them for
     every leftover branch `night-run leftovers` lists, adopted into the night (see Leftovers).
   - `night-run carry <id>` records what earlier days left. Handoffs go to the chat owning them, which
     holds their context (Egor, 2026-10-04; owner: a known To/For chat, else top edit+mention share,
     else the ledger): an owner with a decision section or ≥ 2 handoffs gets one `owner-chat` job,
     its chat resumed with the batch or, live, sent it; ≤ 3 pending, none while `slot_room` finds no room.
     Other handoffs (trivial, chat gone, owner deferred) are `handoff` jobs unless their To/For chat is
     live; each suite the last full run failed is a `suite` job. A handoff settles with a test or as a
     trade (`Cost:`/`Loss:`/`Recommendation:`).
3. **Dispatch.** Everything below starts in parallel at about t+10 min.
   - **Fixers.**
     - `doctor-fix launch <llm|harness|updater|code|system> --night <night-id>` makes one run per area that has
       problems. The areas are the doctor's own menu words, so the night's `<Doctor> fixer: <area>` row
       names a row of that doctor's menu:
       - the LLM doctor's block, or its health row (`debt`);
       - the Harness doctor's section;
       - else `doctor`, the doctor's own problems (the Updater's machinery: `pass-stale`, `cli-behind`, …),
         shown as a bare `<Doctor> fixer`;
       - the Code doctor's one area `code` (`whole` in the same file), also a bare `Code fixer`, its
         run holding the top-K problems only (`docs/doctors-contract.md` §4);
       - the System doctor's one area `system`, a bare `System fixer`, holding only the problems whose top
         cause is an own script of the sweep repositories (`docs/system-doctor-design.md`, Phase 2).
         `share/doctor-areas.json` holds those words and the renamed old
         areas (`llm-health` → `debt`, `harness-self` and `updater-machinery` → `doctor`), so old runs
         keep their label; `tests/test_doctors_menu.sh` checks every label against the rendered menu.
     - Each run gets a worktree on branch `night/<night-id>/<run-id>` and a brief file.
     - The orchestrator starts each brief as a headless worker (`worker-run`, `--workdir` the
       worktree; account from `worker-pick`).
     - Speed's fixer starts only inside a 6-hour wall-clock window from the night's `started_at`: `worker-run`
       runs `night-run speed-gate` once its slot is taken (a `speed-start` event); a first start past the window
       is not launched, its job `left` with `speed window closed (6 h)` and its run abandoned, its levers ranked
       again the next night. `report` shows `speed · levers N selected · S started · L left by the 6 h window`.
   - **Vendors.** `vendor-fingerprint request --night <night-id>` makes one event per vendor with a
     REAL waiting release (no manual full-checklist events at night). Each gets an updater fixer
     run (the printed ref), a worktree on `night/<night-id>/<vendor>`, the same branch's worktrees in
     review-bench and claude-setup as the brief's `ADD-DIR:` lines, and a brief. One headless worker
     per vendor.
   - **Press-time tree.** The orchestrator commits and pushes each sweep repository as it stood at
     press time, one commit each, unreviewed: every branch lands on it, and the debt pass reviews it.
4. **Per branch, as soon as its worker returns** (a completion notification, an owner chat's
   SendMessage, never polling):
   - The run closed: its close gate reran the doctor inside the worktree and passed.
   - No per-branch review (Egor, 2026-10-03: per-branch rounds took about 60% of a night's spend).
   - The orchestrator reads the decision table itself and checks every non-`fixed` verdict. That is
     the second model on a fixer's self-clearing; what it finds goes to the SAME worker (RESUME).
   - `night-run job set … state=merged` still refuses a job whose optional `review` round has open
     findings, until it is fixed through `review-bench fix` or closed `review-bench close <round>
     --nofix --reason '…'`; tonight's merged jobs carry no `review`.
   - A Code fixer job (`code-*`) merges only through `bin/code-doctor check --landing` on its run
     record, against its night base and the main checkouts as they are then (active work,
     revalidation, deletion proof); `night-run job set … state=merged suites=passed` attests the
     suites that passed after the rebase.
   - The branch is rebased onto main's HEAD. The same worker resolves conflicts, since it knows its
     intent. Suites must pass.
   - Commit (one long line) and push.
   - One commit per branch is fine: commit count does not matter to Egor. Merges into main are
     serial and short; everything else is parallel.
5. **Debt pass, after the landings** (the `debt` job, once no other job is `pending`): night-sweep
   step 3 once — one fit round, then one bugs round, each ONE chunked round across all sweep
   repositories, over the press-time debt plus everything the night landed — then one fix pass, the
   commit and push, and the recount. The 150-line floor stays: a round review-bench refuses is skipped.
6. **No deadline** (Egor, 2026-09-30: a 4 h deadline left a debt round's findings unfixed till noon).
   - The orchestrator works until every job is `merged`, `nothing-to-do` or `blocked-on-egor`; a
     job that finishes late is landed like any other, and the debt pass waits for it.
   - The only stop is for a hung job: `worker-run`'s watchdog ends a worker that shows no progress
     (`WORKER_RUN_IDLE_S`, 30 min; a 6 h wall ceiling behind it). The orchestrator then abandons its
     run (`doctor-fix abandon`) and records the job `left` with the watchdog's reason; its branch
     stays unmerged and is named in the report.
7. **Close.**
   - `night-run suites <id>` starts the night's one full `tests/run-all` per sweep repository,
     detached: nothing waits for it (no worker ever runs it); `report` prints its result as weak spots.
   - Rerun the five doctors. This settles the ledger's `fixed-pending` rows into each doctor's overlay,
     never the main checkout. Then, in a worktree of llm-legs on `night/<id>/ledger-sync` from main's
     HEAD, `bin/doctor-fix ledger-sync <worktree>` writes the settled fields into its tracked ledgers;
     commit, land and push that bookkeeping like any branch (nothing printed: nothing to commit).
   - `night-run finish` writes the morning result, then `span-off`. It also removes every landed,
     clean, not live, not held branch of the sweep repositories with its worktree (see Leftovers); it
     prints each one kept as `live|held|leftover <repo> <branch>: <why>`, records the leftovers under
     the night's `leftovers` and the held ones under `held`, and `night-run report` lists both.

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
- The orchestrator chat starts with `CLAUDE_CODE_MAX_CONCURRENT_SUBAGENTS=200`: Claude Code's default 20 would
  refuse the night's ~30 relay agents, and the worker slots' load/memory admission, not that ceiling, decides how
  many run.

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
  - `kind` (fixer, vendor, debt, leftover, handoff, suite, owner-chat) and `ref` (run id, event id,
    review round or `leftover-<slug>`); an owner-chat job carries `owner`, `session`, `via` (open,
    message), `handoffs[]`; a leftover job `adopted[]` ({repo, branch, worktree, tip,
    night_worktree}), where its branch came from, and `handover` ({by, at, why}) when adopted with `--ready`;
  - `state`: `merged`, `left` (with a reason), `failed-launch`, `blocked-on-egor` (its reason the trade) or `nothing-to-do`;
  - `branch`, `review` (run id, optional: a night branch gets no review of its own), `commits[]`
    ({repo, hash}) and `pushed` (bool, as verified against the remote).

- `suites` (the Close run): `started_at`, `finished_at`, `repos[]` {repo, exit, passed, failed[], log}.

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
- `night-run wall` is the `StopFailure` hook (matcher `rate_limit`, wired in the shared
  `~/.claude/settings.json`): when the stopped chat is a running night's orchestrator it starts a
  detached `night-run failover <id> <session>`, logging to `nights/<id>.failover.log`. The failover
  records a `wall` event, polls `worker-pick --account claudeb --role chat --model opus` every
  `NIGHT_RUN_WALL_POLL` s (300) until it names an account with room, then ends the walled chat
  (TERM, KILL after 60 s), records `wall-moved` with the seconds `waited`, and runs `start --resume`.
  It gives up with `wall-gave-up` after `NIGHT_RUN_WALL_LIMIT` s (43200) without room or once the
  night has `NIGHT_RUN_WALL_MAX` (6) walls, and steps aside when the night got another orchestrator
  or finished meanwhile. Account choice stays worker-pick's (no silent rotation): the move is a
  visible resume, the same one a person runs by hand.
- `night-run start --cleanup` opens a new night with the prompt `сделай чистку — night run <id>
  cleanup`: the orchestrator lands the finished night branches and every leftover, and runs the debt
  round, no fixers, no updates.
- The Doctors menu: `Cleanup now` above `Run everything`, behind
  the same Cancel-first confirmation and off while a night runs; under the last night, while it does
  not run, each unfinished job gets `Continue this job` one level down, and one item `Continue
  unfinished (N jobs) + cleanup` resumes them all.

## Leftovers
Egor (2026-10-01): in the sweep repositories no branch or worktree but main outlives the work going on
right now; a kept worktree once lost a review fix.
`night-run leftovers [--json]` lists every non-main branch and worktree with its repository, worktree,
landed (in main or origin/main, or a night branch still at its night's base), ahead/behind main, dirty
count and a state, the one predicate `finish` prunes by; its text form also prints `checkout <repo>: behind
N|diverged[, WIP in the way: <files>]` for a main checkout behind origin/main:
- `live`, never touched: the main checkout, a locked worktree (the owning chat's `git worktree lock`),
  or a branch of a running night. Neither recent activity nor a process inside keeps anything (Egor,
  2026-10-07: finished work commits on its branch in the evening and the night lands it; only an
  explicit block protects a branch): a branch someone is still on stays out only by `сделай холд` or
  its lock. A process inside still keeps the worktree directory from removal (`cwd_held`), never the
  branch from being landed or adopted. `night-run job <id> add leftover <branch> --ready "<why>"`, given when the owning chat
  declared the branch finished, records `handover` {by (`CLAUDE_CODE_SESSION_ID`, else `$USER`), at,
  why} on the job, shown in `night-run report`; a name in several repositories needs `--repo <name>`
  (repeatable) to scope it.
- `held`, not live: Egor's `сделай холд` (word family `night-hold`) in the owning chat runs `night-run
  hold`, which on that chat's fresh grant writes `nights/holds/<session>.json` for its non-main worktrees
  (review journal or cwd); why `Egor: <words>`, refused even with `--ready`, dropped by the next `finish`.
- `landed`: landed, clean, not live, not held; `finish` removes its worktree and deletes the branch.
- `leftover`: everything else (unlanded commits or uncommitted files). It is unfinished work and goes
  into main as a night job. `night-run job <id> add leftover <branch>` adopts it into the night's own
  namespace, where the review-flow gate lets workers commit, in every sweep repository where that
  branch is a leftover (one job; refused if it is live or held in any of them, landed, or unknown). Per
  repository: uncommitted files (`.gitignore` honoured, secret names and big blobs dropped as for the
  base) become one commit `Leftover WIP from <branch>, adopted by night <id>` on the branch;
  `night/<id>/leftover-<slug>` (`/` → `-`, the job's ref `leftover-<slug>`) is made at its tip with its
  worktree at `<repo>/.claude/worktrees/night-<id>-leftover-<slug>`, like every night worktree; then the
  old worktree and branch are removed. It needs `night-run base <id>` first. From there it is a night
  branch like any other, through the per-branch flow; its worker first runs `git rebase
  refs/night/<id>/base`, so the review range and the later `--onto` hold only its own change. A landing
  that fails stays `left`, and a later Cleanup takes it like any other night branch.

`night-run survey [--post] [<repo>...]` is the sweep's opening report (repositories default to the sweep
list; a name resolves through it, a path need not be in it). Per repository `<name> · debt N lines/M
files · due D lines/E files · K dirty · whole|N chunks`, then per linked worktree `  <branch> · +ahead/-behind main · K dirty ·
debt N · take|keep (<reason>)`, closing `total · …`. Debt and the chunk column come from one `review-bench
review --debt --repo <A> … --tier T2 --price`, the due part (stable or critical, what the bugs round
reads) from the same with `--due` (launches nothing; a checkout it does not list owes 0, a
failed price prints `?`); keep is `live` or `held` by the same predicate as `leftovers`, for a
repository outside the sweep list too. `--post` sends the same lines as one report-bus `notice` block
(word `survey`), so the sweep's messages carry facts printed by the machine.

`night-run report [<id>] [--post]` prints it narrowly. First the comparison table from `share/time_budget.py table`,
the numbers block of the morning message, which `--post` also sends to the chat as one report-bus
`notice` block (word `night · <date>`, cells right-aligned in compact columns): one column per night, this one and the two
previous finished nights that had jobs (a night with none is skipped), oldest left, local dates as heads
(with the time when two share a date), right-aligned. Rows are facts the stores already hold: duration;
weighted spend in total and by fixers / reviews / orchestrator; merged, left and blocked-on-egor jobs;
worker runs, their wall, model-active share, hours queued for slots and in their own tests (the ledger's
split); each doctor's problem count before → after; lines changed by the night's jobs (code and tests);
week-old lines rewritten; the full suites run's PASS/FAIL, summed over repositories. A value with no
source is `–`: a suites run still going or never run, a ledger row with no time split, a cached ledger
row from before the spend split whose live re-count no longer matches its total. No ids, no chat names;
a blank line closes it. Then a mechanical header from `share/night_spend.py`,
the numbers of the morning message: duration (local start–finish, hours); jobs landed (state `merged`) / left / other
by kind; the worker runs whose `launcher` is one of the night's orchestrator sessions, started inside
its window, by vendor/served model, with their summed wall-clock hours and any without a transcript;
the review rounds started inside the window whose bench `meta.json` `session` is the night's (one
without that field counts by window alone); token spend of fixers, reviews and orchestrator (output,
cache write, cache read) and one weighted total in input-token equivalents (input 1, cache write
1.25, cache read 0.1, output 5) with its ratio to the newest earlier finished night. Sources: each
run's `session-file`, else `worker-run transcript <run>` (claudeb, codex, gemini and grok alike), a
Claude transcript with its `subagents/`, one assistant message counted once across runs (a RESUME
shares its transcript); a bench's `claude-usage-*.jsonl` by id, plus `usage-<label>.jsonl`
`total_tokens` only where no `claude-usage-<label>.jsonl` holds the same calls (the judge's
`usage-judge.jsonl` sums its `~bN` batches); the orchestrator transcript inside the window. Roots
follow `WORKER_RUN_DIR`, `CLAUDEB_PROFILES_ROOT`, `WORKER_STATS_DIR`/`CLAUDEB_DIR` and the vendor
profile overrides. Then one line per job, then the totals. A job with commits
shows `code +A/-R`: lines its commits add and remove, test paths (`tests/`, `test_*`) left out;
`code ?` when a commit cannot be read. Information only: no threshold. Then `debt now` per sweep
repository: `review-debt --repo --split` at report time (`NIGHT_RUN_REVIEW_DEBT`), the whole and the due
part, `unknown` when unreadable.

Behind the spend lines, an observational churn block from `share/night_churn.py` measures whether the
night did real work or churn: per-branch review rounds versus other rounds; problems touched again without
proof and regressions across doctor runs against the night's problem snapshots (`doctor_problems_before`
and `doctor_problems_after`); fixer spend on runs that left every decided problem unproven; and lines deleted
tonight that were written in the 7 days prior (with earlier night commits noted). It gates nothing.

Last, the ledger from `share/time_budget.py night`: one line for the night (duration; worker wall from each
run's `pid_started_at`, never the slot-restamped `started_at`, split into model time, slot queue and the run's
own suites from the run-suites journal; code and test lines of the job commits and of other commits on the
sweep repositories' HEAD inside the window; week-old rewrites; problems before → after, proved, regressed,
touched again without proof; spend, plus what was deferred: a debt round left or absent), then one trend line
per night for the last 7, oldest first, and their problem direction. A finished night's row is cached in
`${DOCTORS_DIR}/night-ledger/<id>.json`, so it outlives the 7-day run directories and 8-day event files;
nights before the run stamps (2026-10-03) read `not timed` / `?`. The `roi ·` lines close it: each improvement
job (a fixer whose problem is a Speed or time row) with weighted spend, lines and min/day saved once it ran a full
settled day, the night's improvement spend against minutes gained, and the cumulative return over the trend
(rules in `docs/speed-doctor-design.md` §3 ROI).

The Doctors menu shows the last night on one row from `night-run latest --menu`, such as
`Last night 30 Sep: 11 of 13 · 2 unfinished`; its submenu lists every job, done or unfinished, with
the reason in a few words and the whole reason one level down. The state is the color, not words: a
job done and pushed is a dim name alone (one with nothing to do keeps those words), one still owing work (unfinished, in
progress, not pushed) is plain with its word, red only where Egor is needed: a job blocked on him
or a failed launch. Output: a title line `text\ttone\trunning\tid`, then one
`text\ttone\treason\tref\tkind\tresumable` line per job (`tone` 0 dim, 2 plain, 1 red;
`resumable` 1 for an unfinished job of a night that does not run).

## Day Fix button
Unchanged. It opens an interactive chat on one doctor, and that chat pours into main uncommitted.
The night brief and the day chat follow the same procedure file; only the last step differs.
