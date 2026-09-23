# Hand-off: LLM doctor splits WORKER problems from REVIEWER problems and keeps a problem ledger

For the chat that owns LLM doctor: the menubar row `LLM doctor: N issues`, `bin/llm-weather`, and
review-bench's doctor snapshot (row `av`). This comes from the reviewer failure triage done in the chat
"Review-bench improvements phase 4" on 2026-09-23/24. Its findings are the seed ledger below.

## What Egor asked for

1. **Two blocks.** Workers and Reviewers are separate sections of the doctor, and each problem sits in
   exactly one of them. He takes reviewer problems to the review chat and worker problems to whoever owns
   workers.
2. **A ledger per problem.** Each problem records when it was first seen, when a chat last looked at it,
   when it was fixed and in which commit, and whether it came back after the fix.
3. **Something he can see at a glance.** Are bugs growing or shrinking? Which models and which problem
   types dominate, and in which projects?
4. **Doctor first.** A chat asked to fix review or worker trouble reads the doctor first. If the doctor
   lies, the chat fixes the doctor. If it tells the truth, the chat fixes the bugs it reports.

## What exists today, and where it falls short

- **`review-bench doctor`** (`share/rbench/debt.py`, `DOCTOR_CHECKS`, snapshot row `av`).
  - It checks the review *machinery*: `anchors`, `closure_pending`, `debt_line`, `debt_scope`,
    `integrity`.
  - It says nothing about cell failures.
  - It belongs in the Reviewer block as its own "review machinery" group, unchanged.
- **`bin/llm-weather`.** It reads every bench `meta.json` `rater_runs[]` row and every worker-run
  directory, and classifies each leg. The classes are `walled`, `escaped`, `stalled`, `cap`, `failed`
  and `slow`, and the origin is `ours` or `theirs` (row `cq`). It falls short in six ways:
  - **(a) Surfaces are mixed.** It prints one row per model, with the review and worker surfaces merged,
    and `surfaces` only lists which ones appeared. Models that serve both sides, such as opus, grok and
    astra/sol, cannot be read per side.
  - **(b) There is no memory.** It keeps only `latest.json`. Its trend is an arrow for a 2× move of the
    window rate against the 7-day rate. Worker run directories are pruned after 7 days
    (`bin/worker-run`, `find … -mtime +7`), so worker history older than a week is lost unless the
    doctor saves it. `worker-stats/delegations.jsonl` is permanent, has existed since 2026-07-12, and
    records `outcome` ok/failed/usage_limit/killed with `model` and `subagent_type`. It is the only
    long-running worker source.
  - **(c) Superseded attempts count as failures.** Bench `meta.json` keeps every attempt as its own
    row, and the last row for a rater is the final one. If a pool failover recovers the cell, the doctor
    still counts it as a failure. The two cases have to be separate:
    - a **final** failed row means the cell was lost, which is a bug or weather;
    - a **superseded** row that the next attempt recovered means the machinery worked, and it should
      appear only as a weather count.
  - **(d) There is no ledger.** A class looks the same before and after its fix. Most of today's 7-day
    numbers are rows stored before the 2026-09-23 fixes; see the baseline below.
  - **(e) Some worker failures have no owner.** A worker `failed` that no vocabulary word matches
    becomes `exit N` with no origin, for example grok `exit 5` and grok-4.5 `exit 1`.
  - **(f) The "bad" count mixes bugs with correct behaviour.** It includes `cap` and `walled`, which
    are correct behaviour (see the rules).

## Rules the doctor must follow

- **Caps are caps** («Капы это капы»).
  - `cap` means the system did what it should: capacity weather, not a bug.
  - Never count it in the bug total. Never suggest disabling a cell, dropping agy from a tier, or
    raising a cap because of it.
  - Egor's lever for Flash capacity is the Flash 3.8/3.7 menu switch.
  - `walled` (quota) is weather too.
- **The same row can never be both a bug and weather.**
  - **Bugs:** `failed · ours`, `failed` with no origin (a vocabulary gap is a doctor bug: it needs a
    word, or an origin on an existing word), and `escaped`.
  - **Weather:** `walled`, `cap`, `stalled`, `failed · theirs`, `slow`, and superseded-and-recovered
    attempts.
  - The block header counts bugs only. Weather shows dimmed below it.
- **Relabel with current code.**
  - Classify every row from its stored stderr with the current vocabulary, as `llm-weather` already
    does. The ledger's `fixed_at` then splits pre-fix rows from post-fix rows.
  - A matching row after `fixed_at` is a **regression** and must be the loudest thing in its block.
  - A stored kill marker that current code would no longer write is judged from its stderr, not taken
    on trust. Example: agy "print timeout" rows labelled `timeout · ours` on 2026-09-16 would today be
    `watchdog`.
- **Vocabulary parity.**
  - `FAILURE_REASONS` and `FAILURE_ORIGIN` are copied word for word between review-bench
    `share/rbench/panel.py` and `bin/llm-weather`, and row `cq` in `tests/test_consistency.sh` guards
    the copy.
  - A new word lands in both files in the same change.
- **No ids on screen.** A displayed row shows no run id, path or session id (row `av`). Chats appear by
  name, and a click copies the open command the way the existing doctor rows do.
- **One source of truth.** The menu reads the doctor's JSON document and never recomputes. The terminal
  command prints the same document.
- **Tests.**
  - Tests use fixtures only: `CLAUDEB_DIR`, `WORKER_RUN_DIR`, `LLM_WEATHER_DIR`.
  - Never point a check at the live `~/.claude-profiles/.claudeb`, and never mutate the live
    Hammerspoon singleton.
  - Read-only reads of the live stores for diagnosis are fine.

## How to split the blocks

The surface of a leg decides its block:

- **Reviewers:**
  - bench `rater_runs`: review cells, chunks, the verifier and the blind judge, with model, tier and
    project;
  - review-bench doctor snapshot classes, as the "review machinery" group.
- **Workers:**
  - worker-run directories (`~/.cache/claude-worker-runs`, tag `vendor · model`);
  - `delegations.jsonl` for history older than the 7-day prune.

Each block header names its owner chat by name.

- The ledger stores the owner as a role, `review` or `worker`.
- The role-to-chat mapping sits in one place so that Egor can change it. Today the reviewer role maps
  to "Review-bench improvements phase 4". There is no worker owner yet, so show `worker owner: unset`
  until Egor names one.

## The problem ledger

Two constraints fix where the ledger lives:

1. A fix and its ledger row land in the same commit.
2. A triage that ends in "not a bug" also updates the ledger.

So keep it as one repo-tracked JSON file in llm-legs, for example `share/doctor-ledger.json`. Give it a
shared-invariants row and a schema test.

Each row has these fields:

- `id`;
- `block`: `review` or `worker`;
- `matcher`: a vocabulary word, optionally narrowed by a model family and a detail regex;
- `title`: one line;
- `status`: `open`, `fixed`, `not-a-bug` or `weather`;
- `fixed_in`: a list of `repo@hash`;
- `fixed_at`;
- `last_reviewed`: a date;
- `reviewed_by`: a chat name;
- `note`.

`first_seen` and `last_seen` are computed from the data, never typed by hand.

Two mechanical forcing functions keep the ledger honest, so it does not rely on prose:

- A bug-class incident in the window that matches no ledger row shows as **`new`** and counts in the
  block header.
- A `fixed` row with incidents after `fixed_at` shows as **`regressed`**.

The test fails when a vocabulary word that yields a bug class has no ledger row, or when a row names a
word that no longer exists.

## The view

**Menu.** It goes under the existing `LLM doctor` row, beside the current `Review`, `Weather` and
`Gemini` sections, which it may absorb.

- Section headers:
  - `Reviewers: N bugs · M weather`
  - `Workers: N bugs · M weather`
- Each bug row shows:
  - class and models;
  - count in the window;
  - a 14-day text sparkline (`▁▂▃▅▇`) or ↑/↓ against the previous window;
  - last-seen age;
  - status (`new`, `open`, `fixed 3d · 0 since`, `regressed ×N`);
  - `looked at Nd ago`.
- A row opens its incidents: age, model, project, detail.
- Weather rows sit dimmed below the bug rows in the same shape, and they never count in the header.
- A per-block line `top: <model> <class> ×N · …` answers "which model, which problem type".

**Terminal.** One command prints the same two blocks from the same document, with
`--block reviewers|workers`, and it is the first thing a fixing chat runs. Put it at the top of
`docs/DIAGNOSTICS.md`'s symptom table, not in CLAUDE.md prose.

**History.**
- Save a daily rollup of counts per (surface, model, class, origin, final or superseded), for example
  `~/.cache/llm-weather/daily/YYYY-MM-DD.json`.
- Recompute it with current code for every day the stores still hold. A vocabulary fix then relabels
  history.
- Freeze a day once its sources are pruned.
- This is what makes growing or shrinking visible past the 7-day worker prune.

## Seed ledger (block: review, reviewed 2026-09-24 by "Review-bench improvements phase 4")

**Fixed on 2026-09-23.** Commit times: review-bench 08d37c3 at 21:40 +0300, llm-legs 735bb2c at 20:41
+0300, llm-legs bc50235.

| id | problem | fixed in |
|---|---|---|
| R1 | a chunk answering `{"findings":[]}` recorded as `bad output` | review-bench@08d37c3 |
| R2 | grok token not rotated in its last 30 min, so every grok cell was refused | llm-legs@735bb2c |
| R3 | agy Markdown shapes rejected (bare file lists, clean phrasing) | review-bench@08d37c3 |
| R4 | the read-coverage floor discarded answers that had findings | review-bench@08d37c3 |
| R5 | agy print-timeout ceiling and stall mislabelled | review-bench@08d37c3 |
| R6 | claude "no result event" masked a launcher Traceback or EPERM | review-bench@08d37c3 |
| R7 | a credential-export refusal worded "rater task crashed" (now `cell preparation refused`, word `auth`) | review-bench@08d37c3 |
| R8 | vendor policy refusals unclassified (now `refused · theirs`) | review-bench@08d37c3, llm-legs@bc50235 |
| R9 | geminib `capacity hold` read as a model mismatch | review-bench@08d37c3 |
| R10 | stale `killed_chunks` / `max_pass_ms` carried over a rerun | review-bench@08d37c3 |
| R11 | a hung credential export had no timeout (`EXPORT_TIMEOUT_S = 120`) | review-bench@08d37c3 |

**Fixed but waiting for Egor's commit word** (branch `review-cell-labels-2` in both repos):

| id | problem |
|---|---|
| R12 | an export refusal ended the cell instead of trying the pool's next account: claude ×6 on 09-16/17 ("access token expires … short of Ns"), grok ×32 on 09-23 |
| R13 | the agy bare-answer 10-rounds/60-seconds rule false-failed clean reviews (50cea15, 6e4c657); tool reads now decide |
| R14 | codex "flagged for possible cybersecurity risk" was `unclassified` (sol ×3 on 09-22); now `refused · theirs` |

**Looked at and not a bug** (status `not-a-bug` or `weather`):

- agy cap kills, about 97 a week: caps are caps.
- A "6155 s" cell is the sum of 22 chunks, not one cell.
- The 09-16 f5b178f "context canceled" storm was an external SIGTERM at launch. It has not recurred.
- agy "print timeout" rows labelled `timeout · ours` exist only on 09-16. Current code writes `watchdog`.
- codex "no command_execution" is a true label.
- The opus mkstemp and FileNotFoundError crashes were one-offs on 09-12 to 09-14.
- The geminib "sign-in shape" refusals happened on 09-13 only.
- Finding #34, "codex export never renews", was closed as false.

## Baseline for the first render

This covers 7 days to 2026-09-24, classified with current code, superseded rows included.

**Review: 654 legs.**
- Classes:
  - 114 `failed · ours`
  - 24 `cap`
  - 10 `walled`
  - 4 `failed` with no origin
  - 2 `stalled`
  - 1 `escaped`
- `failed · ours` by model:
  - flash37 `bad output` 40
  - grok47 `crashed` 32, all on 09-23 (R2, R7, R12)
  - sol `bad output` 13
  - opus `bad output` 13
  - pro `bad output` 8
  - fable `bad output` 4
- Most `bad output` rows predate 08d37c3. The first real test of the view is whether any rows land
  after 2026-09-23 21:40 +0300. Each one is either a regression (R1, R3, R4) or a new class.

**Worker: 369 legs.**
- Classes:
  - 25 `escaped`
  - 4 `failed · theirs` (astra walled)
  - 3 `failed` with no origin (grok `exit 5` ×2, grok-4.5 `exit 1`)
  - 2 `failed · ours` (opus `auth`)
  - 1 `stalled`
  - 1 `cap`
- Nobody has triaged the worker side. The first item is the 25 `escaped`: are they real writes outside
  the workdir, or is the doctor lying (`files-note` parsing, the scratch-path allowlist)?
- Worker false-green reports and weakened tests are known from past sessions, but no store records
  them. Do not invent a metric for them. List them as "not measurable yet".

## Acceptance

- The menu and the terminal show the Reviewers and Workers blocks from one JSON document. Headers count
  bugs only, and weather is dimmed.
- Every bug row carries the fields listed under "The view". The seed ledger is loaded:
  - R1–R11 read `fixed`, with pre-fix and post-fix counts;
  - R12–R14 read `open` until their commit lands, then `fixed`.
- An unledgered bug class reads `new`, and a post-fix recurrence reads `regressed`.
- Superseded-and-recovered attempts are weather, never bugs.
- The daily rollup survives the 7-day worker prune. The trend covers at least 14 days.
- Documentation and tests:
  - a new shared-invariants row for the document and the ledger;
  - row `cq` parity kept;
  - fixture-only tests;
  - `docs/DIAGNOSTICS.md` updated;
  - no statusline changes.
