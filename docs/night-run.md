# Night run

Owner: the «Updater doctor» chat.

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
   - Before the chat opens, `start` re-checks every answered trade, a `blocked-on-egor` job of another
     night. Recorded answers only, never read from prose: `night-run job <id> set <ref> answer="<his words>"
     done=<check>,…` (`commit:<repo>:<hash>` on main, `file:<path>`, `gone:<path>`, `keep`), or a handoff
     job's doc (its `path`, else the one its ref's slug names) whose `Status:` reads settled. Every check holding (or the doc settled), the job goes
     `settled` with `settled` {at, night, evidence}; otherwise it becomes a pending `trade` job
     `trade-<ref>` of this night carrying the answer and `from` {night, ref, kind, trade, path}, the old job
     marked `carried`, and `carry` gives it a night worktree and a brief. An unanswered trade stays. The
     same check runs when `answer=` is set, so a trade carried out in the chat that got the answer settles at once.
   - The sweep word arms the sweep span. The span carries the review grant, and commit and push, as
     a hand-typed «сделай чистку» does (claude-setup `hooks/lib/word-families.json` family `sweep`).
     The night-sweep skill reads the `night run <id>` marker and follows its **Night mode** section.
2. **Prep** (serial, a few minutes; the orchestrator does it):
   - `vendor-cli-update now --night` runs first and blocks, so CLI installs finish before any worker holds a CLI busy;
     it requests nothing, which would claim the events `request --night` hands to workers.
   - Refresh all five doctors so their documents are fresh. The Code doctor's refresh is
     `bin/code-doctor refresh` (index, journal rollup, candidates), then
     `bin/code-doctor judge --night <night-id>`: worker-run judgments of the waiting candidates,
     stopped by its token and wall budget (`BUDGET`), so a Code fixer only ever sees judged problems.
   - `night-run base <id>` snapshots every sweep repository as it stands, uncommitted work
     included, into `refs/night/<id>/base`, touching neither index nor working tree. Every night
     worktree starts there: main carries days of uncommitted work, and a branch from HEAD would fix
     code that no longer exists. A branch merges only after its repository's press-time debt is
     committed. Land serially through `docs/fix-orchestrator.md`: worker final-commit green proof,
     pre-rebase `tests/affected --overlap <base>` (the night ref only while the branch holds the press
     snapshot, else `git merge-base main HEAD`), rebase, then only that overlap.
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
         `share/doctor-areas.json` holds those words and old areas' renames;
         `tests/test_doctors_menu.sh` checks every label against the rendered menu.
     - Each run gets a worktree on branch `night/<night-id>/<run-id>` and a brief file, as a day launch does
       off main; `docs/fix-orchestrator.md` dispatches and lands them.
     - Speed gets fixers sized per kind, each starting only inside a 6-hour
       wall-clock window from the night's `started_at`: `worker-run`
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
4. **Per branch, as soon as its worker returns**: `docs/fix-orchestrator.md`, then `night-run job set …
   state=merged commits=… pushed=true`. No per-branch review (Egor, 2026-10-03: per-branch rounds took about 60% of a night's
   spend). Merges into main are serial and short; everything else is parallel.
5. **Debt pass, after the landings** (the `debt` job, once no other job is `pending`): night-sweep
   step 3 once — one fit round, one legacy round, then one bugs round, each ONE chunked round across all sweep
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
     detached: no worker waits for it; `report` waits out a live one (`NIGHT_RUN_SUITES_WAIT_S`, 1200 s), FAILs by suite.
   - Rerun the five doctors. This settles the ledger's `fixed-pending` rows into each doctor's overlay,
     never the main checkout. Then, in a worktree of llm-legs on `night/<id>/ledger-sync` from main's
     HEAD, `bin/doctor-fix ledger-sync <worktree>` writes the settled fields into its tracked ledgers;
     commit, land and push that bookkeeping like any branch (no output: nothing to commit).
   - `night-run finish` writes the morning result, then `span-off`. It also removes every landed,
     clean, not live, not held branch of the sweep repositories with its worktree (see Leftovers); it
     prints each one kept as `live|held|leftover <repo> <branch>: <why>`, records the leftovers under
     the night's `leftovers` and the held ones under `held`, and `night-run report` lists both.

## Priority and admission
Egor (2026-10-13): fixing everything is a utopia; night 3131's launch burst walled notcom in 8 min.
- `night-run job add` stamps each job `direction`, `priority` P1|P2|P3 and `value` {n, unit, norm} from
  `share/night_priority.py`: a fixer by its best row as its doctor lists it, other kinds by `KINDS`. Its constants
  are the bars: speed, tests, logs P1 ≥ 15 wall-min/day, P2 ≥ 1; cpu P2 ≥ 30 CPU-min/day, never P1; spend P1 ≥ 0.5 %,
  P2 ≥ 0.1 %; pool, updater P1; legacy, fit, harness P2; bugs P2 only critical on code stable 7 days; unpriced P2.
- `worker-run` asks `night-run admit` before a night worker's slot: P1, then P2, by norm per expected cost (7 days'
  median night-run tokens × 10 % per 1M); running Claude fixers hold at most the pool's 5h room. A P3 runs only from
  weekly room its burn leaves unused at reset (≥ 5 %), else it ends unlaunched (`admission.deferred`, job `pending`,
  no hold on the debt pass, `finish` keeps the reason). Waits are `night-admission` holds.
- Plateau = the P1+P2 backlog at zero (`night_priority.py backlog`, the table's `P1+P2` row); P3 never counts.
- `spend on walls` (report, table row `on walls`, Harness `night_walled` red > 5 %): fixer spend in walled runs.
- Finding is not a job: `log-audit run` and out-of-doctor hunts are never admitted or cut; a class a dig confirms
  gets a doctor meter in the same fix.

## Isolation rules
- A worker never writes the main checkout; a second repository gets its own worktree on the same branch.
- Tests in a worktree run against the job's own worktree set: `share/run-suites.sh` exports a
  sibling repository's worktree on the same branch, else that repository's main checkout (a job that
  did not touch it tests against main, which is its true base).
- Hammerspoon's live config reload ignores `.claude/worktrees/`, so a worktree `.lua` never loads live.
- Accounts: `chat_open` and every worker take a `worker-pick` claim, so parallel launches spread.
- Run records: every read-modify-write takes a lock, and run ids are unique under parallel launch.
- The whole night runs under `caffeinate -i`.
- Every chat gets `CLAUDE_CODE_MAX_CONCURRENT_SUBAGENTS=200` (global settings `env`, default 20); slot
  admission decides how many run.

## Morning record
`~/.cache/doctors/nights/<night-id>.json`:
- `id`, `started_at`, `finished_at`, the orchestrator's `session` and, once resumed, the earlier
  ones in `previous_sessions`;
- `doctors_before` and `doctors_after` (problem counts), and `doctor_states_before`/`doctor_states_after`:
  per doctor the problems of its `latest.json` by ledger state, `proved` (a harness fix proven,
  `fixed · …` per `docs/doctor-fix.md` Proof), `pending` (`fixed-pending` or rule `fix-proof`), `open`,
  `new`, `regressed`. `report` prints one line per doctor,
  `harness 35 → 38 · proved 4 · pending 18 · new 16 · regressed 5`; the menu's Last night shows only the jobs;
- `jobs[]`, each with:
  - `kind` (fixer, vendor, debt, leftover, handoff, suite, owner-chat, trade) and `ref` (run id, event id,
    review round or `leftover-<slug>`); an owner-chat job carries `owner`, `session`, `via` (open,
    message), `handoffs[]`; a leftover job `adopted[]` ({repo, branch, worktree, tip,
    night_worktree}), where its branch came from, and `handover` ({by, at, why}) when adopted with `--ready`;
  - `state`: `merged`, `left` (with a reason), `failed-launch`, `blocked-on-egor` (its reason the trade, `answer`
    {words, at, by, done[]} once Egor answered), `settled` (a trade whose answer start found carried out), `live` (its worker
    run, `run`, still worked at resume) or `nothing-to-do`;
  - `branch`, `review` (run id, optional: a night branch gets no review of its own), `commits[]`
    ({repo, hash}), `integration[]` and `pushed` (bool, as verified against the remote, integration included).
    A merged job whose branch exists records as `commits` only what its branch made (its reflog's non-merge
    commits plus what it was created with past the night's base, found on main by author, author time and
    subject, else on the branch); any other commit `commits=` lists goes to `integration`, never counted as the job's lines.

- `suites` (the Close run): `started_at`, `finished_at`, `repos[]` {repo, exit, passed, failed[], log}.

Jobs start `pending`; `finish` turns any still `pending` or `live` into `left`. `pushed` is set only after
the commits are verified on the remote (`ls-remote` plus ancestry, a missing head fetched); a changed `commits` list clears it until `pushed=true` checks again. A chat that fails to open finishes
the night at once with a note: red in the menu, never blocking a retry; its `pending` and `live` jobs go `left` with that note, and a new
night's carried trades go back to their own nights for the next start.

A night not finished reads `running` while a process carrying its orchestrator's `--session-id`
lives, and `UNFINISHED` (red) once that chat is gone. Before the session is recorded the night
carries `opener`, the pid of the `start` opening its chat, and reads `running` only while that
process lives, so a start killed mid-open never blocks the next one. Only a running night refuses
`start`, and `finish` from any chat but its orchestrator (its `CLAUDE_CODE_SESSION_ID`, or a process under it).

## Continue and Cleanup
- `night-run start --resume <id> [--job <ref>]` reopens the SAME night for a new orchestrator
  (prompt `сделай чистку — night run <id> resume`): `finished_at`, `doctors_after` and `doctor_states_after` go null, the old
  `session` is appended to `previous_sessions`, and the unfinished (`left`, `pending`, `live`) jobs, or the one
  `--job` names, go back to `pending` with their reasons kept, or to `live` (with `run`) while a live worker
  run holds its worktree (start prints `night <id> job <ref> live: worker-run wait <run-id>`). Without `--job` a `debt-<n>` job is
  added when no debt job is pending or live, so a night not finished yet reopens even with every job closed. The review-flow gate reads the night's
  `finished_at` and live `session`, so resumed workers commit on their `night/<id>/…` branches.
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
  a branch of a running night, or a night branch's leftover worktree a process still stands in (a night
  worker outlives a dead orchestrator and cannot ask for a hold). Otherwise neither recent activity nor a process inside keeps anything (Egor,
  2026-10-07: finished work commits on its branch in the evening and the night lands it; only an
  explicit block protects a branch): a branch someone is still on stays out only by `сделай холд` or
  its lock. A process inside still keeps the worktree directory from removal (`cwd_held`), never the
  branch from being landed or adopted. `night-run job <id> add leftover <branch> --ready "<why>"`, given when the owning chat
  declared the branch finished, records `handover` {by (`CLAUDE_CODE_SESSION_ID`, else `$USER`), at,
  why, owner_verified (`by` worked in an adopted worktree: its review journal or cwd, as `hold` reads it)} on the job,
  shown in `night-run report`, an unverified one marked `(never worked in its worktree)`; a name in several repositories needs `--repo <name>`
  (repeatable) to scope it.
- `held`, not live: Egor's `сделай холд` (word family `night-hold`) in the owning chat runs `night-run
  hold`, which on that chat's fresh grant writes `nights/holds/<session>.json` for its non-main worktrees
  (review journal or cwd), a second hold adding to the first; why `Egor: <words>`, refused even with
  `--ready`, dropped by the next `finish`, which is a running night's own: `hold` then names it.
- `landed`: landed, clean, not live, not held; `finish` removes its worktree and deletes the branch,
  except a worktree holding ignored files besides caches (`__pycache__`, `.pytest_cache`, `node_modules`,
  `.venv`, `.DS_Store`): removal would delete them, so it prints `live … it holds ignored files (…)`.
- `superseded`: a night branch, not landed, whose job closed without landing it: `nothing-to-do` (the
  job's verdict is that nothing lands, e.g. main already holds a newer copy) or `settled` (a trade whose
  recorded answer was found carried out elsewhere). `blocked-on-egor` still waits on his answer and
  `left`/`failed-launch` are unfinished work a later Cleanup lands, so those stay `leftover`. In every
  repository the branch is in, it is never adopted (`job add leftover`) nor added to a night (`job add …
  --branch`); `finish` prunes it like a landed one, but only after keeping its tip under
  `refs/night/<night>/pruned/<rest>` and in its job's `pruned[]` {repo, branch, tip, ref, at}, so `git branch
  <name> <tip>` restores it; a worktree with uncommitted files stays (`superseded … , kept`).
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
debt N · take|keep|drop (<reason>)`, closing `total · …`. Debt and the chunk column come from one `review-bench
review --debt --repo <A> … --tier T2 --price`, the due part (stable or critical, what the bugs round
reads) from the same with `--due` (launches nothing; a checkout it does not list owes 0, a
failed price prints `?`); keep is `live` or `held` by the same predicate as `leftovers`, for a
repository outside the sweep list too. `--post` sends the same lines as one report-bus `notice` block
(word `survey`), so the sweep's messages carry facts printed by the machine.

`night-run report [<id>] [--post]` prints it narrowly. First the morning numbers blocks, each closed by a blank line, no
ids or chat names, `–` for no source; `--post` sends each to the chat as a report-bus `notice` block instead:
- `time_budget.py table` (word `night · <date>`): this night and the two previous finished nights with jobs,
  oldest left, local dates as heads (with the time when two share one). Rows: duration;
  Opus-eq spend in total and by fixers / reviews / orchestrator; merged, left jobs; `needs Egor`, every open trade
  to him once (`handoffs.py --trades`: unanswered blocked-on-egor jobs, handoffs whose Status reads trade, audit rows
  with verdict `trade`, doctor rows with `needs_egor`; rows naming one handoff are one, a settled one none), stored
  at the close; worker runs, wall, model share, slot queue, own tests; problems per doctor; job lines; week-old
  rewrites; suites ✓/✗.
- `time_budget.py directions` (`night · directions`): per direction open P1, P2 at the close, ✓ jobs landed or ruled
  out, % of fixer spend (runs by night worktree), nights to plateau (open / closed a night over the nights that
  recorded it, `–` once grown or none closed); all-zero rows left out; kept in the ledger row's `directions`.
- `time_budget.py pool` (`night · improvement pool`): open, done, proven, kept, trade per class, totals last: spend,
  suite, cpu (audit ledger, Speed's due selections and proofs), harness, logs (harness ledger).

Then `share/night_spend.py`'s header: duration; jobs landed / left / other by kind; the worker runs the
orchestrator sessions launched in the window, by vendor/served model, with wall hours; the session's review rounds;
spend of fixers, reviews and orchestrator in Opus-eq by model against the newest earlier finished night, priced by
token-map's `tokenmap/pricing.py` (`TOKENMAP_ROOT`; absent, the report fails), Opus input = 1, from each run's
transcript (a message once across a RESUME), the benches' usage journals and the orchestrator transcript in the window. Then a line per job and the
totals; a job with commits shows `code +A/-R` (test paths `tests/`, `test_*` left out), `code ?` when a commit is
unreadable. Then `debt now` per sweep repository: `review-debt --repo --split` (`NIGHT_RUN_REVIEW_DEBT`), whole and
due, `unknown` when unreadable.

Behind the spend lines, `share/night_churn.py`'s churn block, gating nothing: per-branch versus other review rounds;
problems touched again without proof and regressions against `doctor_problems_before`/`_after`; fixer spend on runs
leaving every decided problem unproven; lines deleted tonight written in the prior 7 days.

Last, `share/time_budget.py night`'s ledger: one line for the night (duration; worker wall from each run's
`pid_started_at`, never the restamped `started_at`, split into model, slot queue and own suites; code and test lines
of the job commits and of other commits on the sweep HEADs in the window; week-old rewrites; problems before → after,
proved, regressed, touched again without proof; spend and what was deferred), then a trend line per night for the
last 7, oldest first, and their problem direction. A finished night's row is cached in
`${DOCTORS_DIR}/night-ledger/<id>.json` (outliving 7-day runs and 8-day events); one without `spend_unit` `Opus-eq`
is re-priced live once, one without `directions` gains them once. The `roi ·` lines close it: each improvement job (a
fixer on a Speed or time row) as what · spend · lines · before → after unit · verdict · gain a day, then the night's
and the trend's totals (`docs/speed-doctor-design.md` §3 ROI).

The Doctors menu's last-night row comes from `night-run latest --menu`, e.g. `Last night 30 Sep: 11 of 13 · 2
unfinished`; its submenu lists every job with its reason in a few words (whole one level down), then `✓ done`,
`→ queued` and red `! To: Egor` handoff rows with a count, each title one level down to its doc (`handoffs.py
--night`: the night's carried handoffs by their Status, open ones, the trades). Color is the state: done and pushed
is a dim name (nothing to do keeps those words), owing work (unfinished, in progress, not pushed) plain with its word,
red only where Egor is needed (blocked on him, failed launch). Output: `text\ttone\trunning\tid`, then
`text\ttone\treason\tref\tkind\tresumable` per job (`tone` 0 dim, 2 plain, 1 red; `resumable` 1 for an unfinished
job of a night not running), then `handoff\tphase\ttitle\tpath` per handoff.
