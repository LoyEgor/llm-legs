# Lost time (direction 2)

Wall-clock the harness adds to chats and workers: test runs and their queues, slot waits, Bash-cap reruns, hook
latency, wrap-up, retries, usage walls.

## Metric

The Lost time index in the Doctors menu: overhead per unit of work against the previous 7 days, where 1.00 means
unchanged. It is a Paasche index over two strata, chat orders and worker tasks (`time_budget.paasche`). Read it with
`share/time_budget.py day [--json]` (`index`, `index_window`). For a single suite, CPU is the honest number, since
wall time follows the machine's load.

### Baseline (computed 2026-10-16)

The windows are 10-08…14 against 10-03…07 (5 days), the same as Breakages', because the unit journals start on
10-03. 10-15 settles only on 10-17, and its worker rows sit in the account store this baseline may not read.

| | 10-03…07 | 10-08…14 |
|---|---:|---:|
| units: chat orders / worker tasks | 405 / 450 | 819 / 1,133 |
| min per order · chat | 2.93 | 1.75 |
| min per task · workers | 42.5 | 20.0 |
| **Lost time index** | 1.00 | **0.48** |
| min/day: tests (running + slot wait) | 965 (964 + 282) | 562 (562 + 110) |
| min/day: waiting for workers · hooks and gates · usage walls | 261 · 166 · 57 | 94 · 29 · 36 |
| min/day: wait overshoot (journal from 10-11) | | 12 |
| suite runs/day · suite CPU-min/day · CPU-min per unit | 3,613 · 1,281 · 7.5 | 4,922 · 1,456 · 5.2 |

- Method: strata, units and rows from `~/.cache/harness-doctor/budget-days/<day>.json` (`strata`, `rows`, `parts`,
  BUDGET_VERSION 5), summed over a window's days and divided by their count. Index = Σ window overhead / Σ (window
  units × prior overhead per unit), per stratum as `time_budget.paasche`. A row is the union of its parts' spans, so
  the bracketed parts overlap. Suite runs and CPU from `~/.cache/run-suites/runs.jsonl` by local day of
  `queued_at`: a run is one entry of a line's `suites`, CPU is Σ `suites.*.cpu_s`, per unit divides by chat orders +
  worker tasks (855; 1,952). Some lines hold two JSON objects: decode with `json.JSONDecoder().raw_decode`.
- `index_by_day` cannot recompute it (7 against 7 days reach 10-01, before the journals): use `budget-days/`. Live
  cross-check (`latest.json` → `speed.budget.index_window`, 10-10…16 against 10-03…09): 0.64 at 10-16 19:51.

## Sources

- Index, rows and waits: `share/time_budget.py`, reading `~/.cache/harness-doctor/events/` and `waits`, the
  worker-stats `runs.jsonl` and the run-suites journal; settled days in `budget-days/`.
- Suite runs, CPU, callers, trees: `~/.cache/run-suites/runs.jsonl`; `worker_run`/`session` = caller, `kind`/`scope`
  = direct, targeted (`named|changed`) or full, `tree` a content digest from 10-09 21:14 (reworked 518a3523, 10-13).
- Catches: `~/.cache/harness-doctor/test-catches.json` from 10-03, a caller's red → code edit → green. Close's full
  run (`night-run suites`, every night, pilot ones too; `~/.cache/doctors/nights/<id>.json` → `suites.repos[].failed`
  after one rerun) has no transcript, so its reds count as `unread`, never as catches.
- Test health: `latest.json` → `speed.tests` (`findings`, `fan_out`, `heavy`, `catches`), from `share/test_health.py`.
- Suite audits: `share/suite_audit.py` `due()`; rows `suite:` in `share/spend-ledger.json`; due ones are the
  `suite_audit` problems in `latest.json` → `speed.problems`, reason after `audit due:`.
- Ledger rows: `share/harness-ledger.json`, rules `opportunity` (test-health, `chat/tests`), `regression`, `test_*`,
  `tool_idea`, `wait_class`, `hook_*` and `floor` (Speed's, outside Breakages' sum), `log_audit`. Commits: git.

## Recurring classes

Each class was fixed as an instance and came back. Ranked by harness-ledger rows, as of 2026-10-16.

| class | rows | fixes | fix days | what makes it come back |
|---|---:|---:|---|---|
| a hook's latency is cut hook by hook (full work, sync, growth, every call, p50, floor) | 64 | 64 (6 rows twice+, 15 came back) | 09-29…10-10 | each hook is cut alone (the dispatcher was declined 10-05), so a new or grown hook repeats the shape |
| a slow suite is shaved one at a time (heavy, pole, daily cost, long pole, slow) | 57 | 76 (17 rows twice+) | 10-01…13 | the cost is runs × wall and each fix cuts one suite's seconds; test_health's heavy and pole findings file a suite again beside suite_audit's own queue |
| a run dies at the Bash cap or is queued past it (test_hang, log audit, `tool-idea-run-all-attach`) | 22 | 13 | 10-07…14 | Breakages' `bash-cap` |
| a suite idles on a fixed sleep or poll | 18 + 4 | 14 | 10-05…14 | each suite and model writes its own wait loop |
| a suite is reopened on a number not its own: any edit of a source it shares, or wall read under load | 18 + 203 of 252 moved | 13 | 10-10…14 | `due()` reopens on `spend.moved` (an edit) before any measured rise; `load()` reads 1.0 with fewer than 3 controls |
| a targeted run carries suites that never catch | 5 + 5 commits | 2 + 5 | 10-04…14 | each fix narrowed one rule (ad5d95f9, 506ed8cc, 3e34ec7a, 477ffb74, ffcaf829); suites reached through an import or a helper, with no catch, remain |
| a caller reruns a suite on content already green | 4 + 8e6961df | 2 | 10-10…14 | each caller (worker, chat, landing, night) decides alone; a prose rule binds only its readers |

- Row selection in `share/harness-ledger.json` (`match.rule`, `match.ident`; fixes = `fixes[]`, days = their `at`):
  - hooks: rules `hook_*` (57) + `floor` (7); a fix with `regressed_at` is one the row came back after.
  - shaving: rules `test_slow`, `test_daily_cost`, `test_long_pole` (14) + `opportunity` idents matching
    `test-health/\(?(heavy|pole)` (43, `(heavy|idle)/…vendor_files` included).
  - reopened: `suite:` rows of `share/spend-ledger.json` whose `sources` blob differs from `git rev-parse HEAD:<path>`
    (203; `tests/lib/suite-journal.sh` moved in 160, the only moved source of 72) + every `regression` row but
    `test-health/retests`, `/targeted`: 14 `fix/…` (8 fixes, 10-13…14; 11 suite fixes, 6 closed ruled-out: 4 noise or
    load, 1 coverage growth, 1 leaked worktrees), 4 `test-health/{pole,wait_night,wait_chat,idle}` volume rows (5 fixes).
  - bash cap: `test_hang` (13 rows, 9 fixes) + 8 `log_audit` rows on the 10/25-min cap or slot queue (4 fixes) +
    `tool-idea-run-all-attach`. fan-out: `opportunity` `test-health/fan-out/*` (3, 2 fixes),
    `log_audit:tests-affected-over-selection`, `tool-idea-run-all-affected`.
  - idle: `opportunity` `test-health/idle/*` (18, 14 fixed) + `time/wait_loop`, `log_audit` `sleep-poll-loops-waiting`,
    `slot-throttle-foreground-sleeps`, `worker-suite-run-waits` (4, no fix); 10-05 is c4adcbb8's sleep cut, no row.
  - green reruns: `regression` and `opportunity` `test-health/retests`, `regression` `test-health/targeted`,
    `log_audit:landing-pipeline-retests-and-mistakes`; `known-red-suites-rediagnosed` is a red base, no rerun.
- Measured weight, 10-08…14:
  - 37 % of targeted suite runs (22 % of their CPU, 272 of 1,210 CPU-min/day) went to suites with no catch since
    10-03 (suite `basename(repo_root)/<stem>`, caught = a key of any `days.*.catches`; targeted = `scope` `named`
    or `changed`, by local day of `queued_at`; 27,901 runs).
  - Retests (a suite rerun on a (`repo_root`, `tree`) with an earlier `rc` 0, by `queued_at`): 276 runs/day, 84
    CPU-min/day 10-09 21:14 → tests-once (10-14 15:42, 4.77 days); 36/day, 7 CPU-min/day to 10-16 00:00 (1.35).
  - Wait overshoot (`budget-days` `rows`): 8, 34, 38 min/day on 10-12…14; 32 of 10-14's on suites (`waits.on`).
  - Idle (Σ `min_day`, class `idle`, `speed.tests.findings`, live): 6.3–7.8 min/day on 10-16. Hooks (`parts.hooks`):
    156 → 20 min/day, `commit-report.sh` 11.5 of the 20 (`hooks_by_hook`).
- No goal for hooks (10-05; no new hooks), idle (little to gain; a race check's sleep stays) or green reruns (10-16,
  10-07; tests-once is young, the open `regression` `test-health/retests` row reads it). No class for usage walls or
  waiting for workers: two log-audit rows fixed 10-08, the rest weather or chat conduct; the worker queue is
  protection (10-14).

## Goals

Worked in order, one at a time; a landed goal moves to Done with commit and proof, a failed one stays with what
blocked it. Breakages' `bash-cap`, this direction's largest wait, is not repeated. Each proof replays fixed journals:
a 7-day window after landing moves with the pilot's volume (no `doctor-fix launch`, so no suite audits; targeted
suite CPU 1,210/day in 10-08…14, 113 on 10-15) and tests-once.

### goal night-owned: the night hub session is owned whole, as its own stratum

Class: a caller the index does not own sits outside it, so the pilot night's own work never reaches it (first for
that). A hub chat's first message `сделай чистку — night run <id>` matches `C1_MACHINE` in `bin/harness-doctor`, so
its session is `own=False`, with no `t` rows: its suites land in `out_s.suites` (509 → 261 wall-min/day, 46 % of
the tests row; 438 CPU-min/day, 30 % of suite CPU in 10-08…14: hub chats 396, Close's `night-run suites` 40, which
strips the session, `bin/llm-selfcheck` 1.6), its hooks, waits and refusals in `agents[None]`, in no stratum.
- The change is in llm-legs `share/time_budget.py` `budget()`: a third stratum `night`, units the jobs of the nights
  finished that day (`~/.cache/doctors/nights/<id>.json` `jobs`), agent the night record's `session`, owning its
  suites, hooks, waits and refusals, and Close's suites. Chat and workers strata stay as they are, so the index stays
  per unit (2026-10-11); `out_s.suites` keeps the rest; BUDGET_VERSION 6. Bench suites stay out.
- First step, unconfirmed: `session` is the hub's, how Close's session-less rows tie to their night, job counts
  (≈181 / 275 in the windows, by UTC start) and the projection (night min/job, index; `budget-days` has no per-session split,
  the old 0.48 → 0.46 put suites in workers with no units: void), recomputed from the journals before the change.
- Proof, version 5 → 6 on the same journals: chat and workers strata unchanged, night as projected. Must not get
  worse: no night-session span in `agents[None]`, `out_s.suites` at most selfcheck's.

### goal fan-out: a targeted run carries a file's own suite and, of the rest, only suites that catch

Class: targeted runs carry suites with no catch (weight above, 242 of the 272 CPU-min/day in runs of 6+ suites),
after five commits narrowed the selection one rule at a time.
- The change is in llm-legs `share/suite_select.py`: a suite with no catch in `CATCH_D` days, journaled 7 days or
  more (test_health's fan-out `zero` set plus that age), leaves the targeted output unless it is a changed file
  or named after one (`named()`), so every file keeps its own unit suite.
- In `share/test_catches.py`, a suite red at one night's Close and green at a later Close counts as a catch; one
  still red counts as nothing, so known-red suites are not kept alive (Legacy's). A dropped suite runs only at
  Close, whose reds are `unread`, and a pilot night carries no job for them: without this it could never catch
  again, and the 90-day rule would delete it on no evidence. Test_health's fan-out finding and its pricing go.
- Proof, old → new on one journal: `select()` replayed over the commits the four sweep repositories landed in the 7
  days before landing, each suite at its median passing targeted run of those days (`runs.jsonl`): suite wall-min a
  commit, CPU beside. 10-08…14 (1,580 commits, catches of 10-16; `git log --no-merges --name-only` per repository,
  HEAD's `select()` and `tests/`; 206 of 20,582 selections unpriced): 6.4 → 5.3, CPU 3.9 → 3.4, suites 13 → 9.3.
  −17 % is an upper bound: that replay ignored the 7-day age rule, which the proof applies.
- Must not get worse: missed catches, dropped suites that went red at Close over 7 nights, beside their Close runs
  (never 0). Target 0; each is named, and one a targeted run would have caught stops the goal.

### goal suite-own-cost: a suite's cost has one queue, its rise read under load

Class: a slow suite is shaved again by test_health's heavy and pole findings beside suite_audit's queue, and a
held rise is read without the machine's load.
- The change is in llm-legs `share/suite_audit.py` `due()`: the held 2× rise is read through `load()` as `jump()`
  already is, and `load()` with fewer than LOAD_CONTROLS controls reads unknown, never 1.0, the rise then read on
  CPU a run (`test_health.cpu_run`). The source-edit reason (`spend.moved`) stays: re-audits on a source edit landed
  a measured drop to ≤ 0.65× wall a run in 13 of 61 suites (kept rows 0 of 15), ≈ 66 wall-min/day for 0.42 % of
  Claude spend, a first audit's price per find (2026-10-20 night-cost research).
- In `share/test_health.py` the heavy and pole findings and their pricing go: suite_audit prices every suite.
- Proof, old → new on one `runs.jsonl`, `spend-ledger.json` and HEAD: test_health's heavy and pole findings on a
  suite suite_audit already prices, before (unconfirmed; counting them is the first step) → 0; old and new `due()`
  differ only in rises the load explains, each listed with its load.
- Must not get worse: no suite gets slower unseen. In the 7 days after landing, a risen suite (≥ 2× held over
  HELD_S) over the floor that is not due fails the goal.

## Done

| date | change | result | evidence |
|---|---|---|---|
| 10-01 | `test_worker_run` (7,755 lines) split into 16 suites | slowest part 2,287 → 233 s | 8f113a19 |
| 10-04 | workers run only the covering suites (`tests/affected`) | | ad5d95f9 |
| 10-05 night 052f | slot admission, fixed sleeps cut, `test_instruction_gate` split in 8, answer-pty hang, slot_wait orphan race | median suite run 160–240 → 35 s at ×1 cost | c4adcbb8, 03001c01, 6389e500 |
| 10-10 | lifecycle, outcomes, consistency sharded | | |
| 10-13/14 nights | 252 suite audits (170 cut, 81 kept, 1 trade; `suite:` rows); on 10-13, 166 tests touched, 72 faster, 41 slower | a pass 59 → 50 min, below day-to-day noise, at ×4.5 the 10-05 cost | |
| 10-14 | tests run once, when the work is done | runs per worker task 7.7 → 3.3, retests 276 → 36/day; only 22 tasks so far | 8e6961df |

## Open

- Index coverage: `out_s.unmeasured` (426 → 2 min/day) sits outside the index; the night hub is `night-owned`.
- Fixed-sleep polls (`tool-idea-wait-until`): ≈121 min/day estimated, the overshoot above measured; the tool waits
  until the overshoot outgrows what Breakages' `bash-cap` (deleting worker-run's `CLAUDE_CODE_DISABLE_BACKGROUND_TASKS`
  export) covers.
- `tests/affected` basename rule, no goal: 2 of 21,646 selections on 10-08…14; 10-15's 38 suites came from the new
  `docs/directions/` files before a suite named them (`docs/zz/README.md` still pulls 38).
- Expected gains were inflated (10-14: 3,493 min/day expected from tests, the whole row ≈550): price from the journal.

## Decisions

- 2026-10-16: audit reopens belong to the audit that makes them: `suite_audit` (an edit, load read as slower) here,
  `spend_audit` Spend's, `cpu_audit` System's. `green-once` dropped: ≈7 CPU-min/day after tests-once, for a cache.
- 2026-10-15: obsolete test checks belong to Legacy. («Updater doctor»)
- 2026-10-14 («Updater doctor»): tests are the disease, the worker launch queue is protection: no goal shrinks a
  queue by launching less. Tests run once, when the work is done, and only where the change reaches: 72 suites for
  a one-file edit, with no catch to show for it, is a fault the night fixes. A suite counts only while its owner
  waits on it, never while the owner generates beside it; a model's sleep or poll counts only past the end of what
  it awaits. Model-written scripts and our tools stay outside the index.
- 2026-10-14: the statusline refresh stays 3 s; only the per-render cost is cut. («Передача system-doctor-ux»)
- 2026-10-13: speed here is less delay, not less CPU: a goal is proven on wall minutes, CPU only beside them.
  («Updater doctor»)
- 2026-10-11: the index has no norm or target, only the previous 7 days; it never moves with work volume,
  parallelism, vendor, night or day, or his presence. («test and lost time optimization»)
- 2026-10-10: Lost time is every machine overhead around the work (tests in full, waits, hooks, gate refusals,
  usage walls), never work he chose (model and tool work, reviews), as a wall-clock union so parallel waits never
  add up; counted simply from existing journals, never fragile logic for a few % of precision. («test and lost time
  optimization»)
- 2026-10-08: a chat's full `run-all` only on Egor's word (847c18ad). («Updater doctor»)
- 2026-10-07: pass reuse on identical inputs was built and dropped, never to be rebuilt (ledger, `retests`).
- 2026-10-07: concurrency is judged by final speed: take what the Mac has free by load and memory, never freeze it;
  a queue that gives a faster total stays. («Night run cleanup»)
- 2026-10-07: never shorten a sleep or timeout a race check depends on: the 10-05 cuts that did went vacuous and
  were reverted. («Updater doctor»)
- 2026-10-05: the hook dispatcher was declined; hooks are cut one by one, dearest first. A speed trade comes to
  Egor as min/day and share of the total. («make land for multiple workers in one repository»)
- 2026-10-04 («make land for multiple workers in one repository»): every wait (slot, queue, lock, poll) is journaled
  where the doctors read it and shown even when normal; the measuring itself adds no wait (10-06, «Чистка night run»).
- 2026-10-03: speed never trades model, effort or thinking. («Updater doctor»)
- 2026-09-23: no serial machine-wide test queue: contention is met by lower priority (nice), and any hold tells the
  held chat and the menubar. («Updater doctor»)
