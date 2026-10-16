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
- `index_by_day` cannot recompute this baseline (7 days against 7 reach 10-01, before the journals): use `budget-days/`.
- Live cross-check: the doctor's `index_window` at 10-16 19:51 (10-10…16 against 10-03…09) read 0.64; 0.62 at
  23:15 (`latest.json` → `speed.budget.index_window`).

## Sources

- Index, rows and waits: `share/time_budget.py`. It reads `~/.cache/harness-doctor/events/`, the worker-stats
  `runs.jsonl`, the run-suites journal and `~/.cache/harness-doctor/waits`. Settled days are kept in `budget-days/`.
- Suite runs, CPU, callers and trees: `~/.cache/run-suites/runs.jsonl`. `worker_run`/`session` give the caller,
  `kind`/`scope` say direct, targeted (`named|changed`) or full, and `tree` is a content digest from 10-09 21:14
  (hash reworked by 518a3523 on 10-13).
- Catches: `~/.cache/harness-doctor/test-catches.json` from 10-03, a caller's red → code edit → green. Close's full
  run (`night-run suites`, every night, pilot ones too; `~/.cache/doctors/nights/<id>.json` → `suites.repos[].failed`
  after one rerun) has no transcript, so its reds count as `unread`, never as catches.
- Test health: `latest.json` → `speed.tests` (`findings`, `fan_out`, `heavy`, `catches`), from `share/test_health.py`.
- Suite audits: `share/suite_audit.py` `due()`; rows `suite:` in `share/spend-ledger.json`; due ones are the
  `suite_audit` problems in `latest.json` → `speed.problems`, reason after `audit due:`.
- Ledger rows: `share/harness-ledger.json`, rules `opportunity` (test-health, `chat/tests`), `regression`, `test_*`,
  `tool_idea`, `wait_class`, the hook rules `hook_*` and `floor` (Speed's, outside Breakages' sum) and the
  `log_audit` rows. Commits come from git.

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
  - reopened: `suite:` rows of `share/spend-ledger.json` whose `sources` blob differs from `git rev-parse
    HEAD:<path>` (203; `tests/lib/suite-journal.sh` moved in 160, the only moved source of 72) + every `regression`
    row but `test-health/retests` and `test-health/targeted`: 14 `fix/…` (8 fixes, 10-13…14; 11 are suite fixes,
    6 closed ruled-out: 4 as noise or load, 1 coverage growth, 1 leaked worktrees) and 4
    `test-health/{pole,wait_night,wait_chat,idle}` volume rows (5 fixes).
  - bash cap: `test_hang` (13 rows, 9 fixes) + 8 `log_audit` rows on the 10/25-min cap or slot queue (4 fixes) +
    `tool-idea-run-all-attach`.
  - idle: `opportunity` idents `test-health/idle/*` (18, 14 fixed, 10-10…14) + `time/wait_loop` and the `log_audit`
    rows `sleep-poll-loops-waiting`, `slot-throttle-foreground-sleeps`, `worker-suite-run-waits` (4, no fix); 10-05
    is the c4adcbb8 sleep cut, a commit with no row.
  - green reruns: `regression` and `opportunity` `test-health/retests`, `regression` `test-health/targeted`,
    `log_audit:landing-pipeline-retests-and-mistakes`; `known-red-suites-rediagnosed` is a red base, no rerun.
  - fan-out: `opportunity` `test-health/fan-out/*` (3, 2 fixes), `log_audit:tests-affected-over-selection`,
    `tool-idea-run-all-affected`.
- Measured weight, 10-08…14:
  - 37 % of targeted suite runs (22 % of their CPU, 272 of 1,210 CPU-min/day) went to suites with no catch since
    10-03: a suite is `basename(repo_root)/<stem>`, caught when it is a key of any `days.*.catches`;
    targeted = `scope` `named` or `changed`, by local day of `queued_at` (27,901 runs).
  - Retests (a suite rerun on a (`repo_root`, `tree`) with an earlier `rc` 0): 276 runs/day, 84 CPU-min/day from
    10-09 21:14 to tests-once (10-14 15:42); 36/day, 7 CPU-min/day from then to 10-16 00:00 (by `queued_at`, over
    the exact spans, 4.77 and 1.35 days).
  - Wait overshoot (`budget-days` `rows`): 8, 34, 38 min/day on 10-12…14; 32 of 10-14's on suites (`waits.on`).
  - Idle findings (Σ `min_day` of class `idle` in `speed.tests.findings`, live): 6.3–7.8 min/day on 10-16 (7.8 at
    23:15).
  - Hooks (`parts.hooks`): 156 → 20 min/day, `commit-report.sh` 11.5 of the 20 (`hooks_by_hook`).
- No goal for hooks (10-05; no new hooks), idle (little to gain; a race check's sleep stays) or green reruns (10-16,
  10-07; 1.3 days of tests-once so far, so the open `regression` `test-health/retests` row keeps reading it).
- No class for usage walls or waiting for workers: two of their log-audit rows were fixed 10-08, the rest are
  weather or chat conduct (`night-stalls-on-account-limit`, …); the worker queue is protection (10-14).

## Goals

The pilot night works these goals in order, one at a time; a landed goal moves to Done with its commit and proof, a
failed one stays with a line on what blocked it. Breakages' `bash-cap`, this direction's largest wait, is not
repeated here. Each proof replays fixed journals: a 7-day window after landing moves with the pilot's volume (no
`doctor-fix launch`, so no suite audits; targeted suite CPU 1,210/day in 10-08…14, 113 on 10-15) and tests-once.

### goal night-owned: a suite with no worker and no chat owner counts in the index, as the night's

Class: a caller the index does not own sits outside it, so the pilot night's own suites never reach it (first for
that). `out_s.suites` (509 → 261 wall-min/day, 46 % of the tests row; 438 CPU-min/day, 30 % of suite CPU in
10-08…14) by CPU: night hub chats 396 (90 %; their first message `сделай чистку — night run <id>` matches
`C1_MACHINE` in `bin/harness-doctor`, so the session is `own=False` and writes no `t` rows), Close's `night-run
suites` 40 (it strips the session), `bin/llm-selfcheck` 1.6.
- The change is in llm-legs `share/time_budget.py` `budget()`: such a suite joins agent `("workers", "night")`;
  `outside` and `out_s.suites` go (`out_s.unmeasured` stays); BUDGET_VERSION 6. Bench suites stay out.
- Proof, version 5 → 6 on `budget-days` 10-03…07 → 10-08…14 (projected now by adding `out_s.suites` to the
  workers stratum's `overhead_s`, units unchanged): outside 509/261 → 0 min/day, workers min/task
  42.5/20.0 → 48.2/21.6, index 0.48 → 0.46; chat stratum, tests row and units unchanged. The baseline then takes
  the version-6 numbers. Must not get worse: no non-bench suite outside every stratum.

### goal fan-out: a targeted run carries a file's own suite and, of the rest, only suites that catch

Class: targeted runs carry suites with no catch (weight above, 242 of the 272 CPU-min/day in runs of 6+ suites),
after five commits narrowed the selection one rule at a time.
- The change is in llm-legs `share/suite_select.py`: a suite with no catch in `CATCH_D` days, journaled 7 days or
  more (test_health's fan-out `zero` set plus that age), leaves the targeted output unless it is a changed file
  or named after one (`named()`), so every file keeps its own unit suite.
- In `share/test_catches.py`, a suite still red after Close's rerun counts as a catch. A dropped suite runs only at
  Close, whose reds are `unread`, and a pilot night carries no job for them: without this it could never catch
  again, and the 90-day rule would delete it on no evidence. Test_health's fan-out finding and its pricing go.
- Proof, old → new on one journal: `select()` replayed over the commits the four sweep repositories landed in the 7
  days before landing, each suite at its median passing targeted run of those days (`runs.jsonl`): suite wall-min a
  commit, CPU beside. 10-08…14 (1,580 commits, catches of 10-16): 6.4 → 5.3 (−17 %), CPU 3.9 → 3.4, suites 13 → 9.3.
  That replay (`git log --no-merges --name-only` per repository, HEAD's `select()` and `tests/`; 206 of 20,582
  selections unpriced) left out the 7-day journal age, so −17 % is an upper bound; the proof applies it.
- Must not get worse: missed catches, dropped suites still red after Close's rerun over 7 nights, beside their Close
  runs (never 0). Target 0; each is named, and one a targeted run would have caught stops the goal.

### goal suite-own-cost: a suite's cost has one queue, due only on the suite's own slower run

Class: a suite is reopened on a number not its own, and a slow suite is shaved again by test_health's heavy and
pole findings beside suite_audit's queue.
- The change is in llm-legs `share/suite_audit.py` `due()`: the `spend.moved` reason goes, with `changed_at`; the
  held 2× rise is read through `load()` as `jump()` already is, and `load()` with fewer than LOAD_CONTROLS controls
  reads unknown, never 1.0, the rise then read on CPU a run (`test_health.cpu_run`). A suite is due only on such a
  rise, never audited, a new heavy suite or dead. Spend and System keep their own `spend.moved` callers.
- In `share/test_health.py` the heavy and pole findings and their pricing go: suite_audit prices every suite.
- Proof, old → new on one `runs.jsonl`, `spend-ledger.json` and HEAD: old and new `due()` against the suites
  whose own wall floor or CPU a run is ≥ 2× their audit's (`price()` against the rows' `wall_run`, `cpu_run`,
  without `due()`). 10-16 21:40: old 103 due, 102 of them `source changed`; risen over the floor 0 of 252, so new 1
  (never audited); 3 suites risen ≥ 2×, all under FLOOR_MIN_DAY (`suite_audit.collect(now)`, risen from
  `price(runs(journal, now − 7 d))`, recomputed at 23:24: same). The new set must equal the risen suites plus never audited, new
  heavy and dead.
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

- Index coverage: `out_s.unmeasured` (426 → 2 min/day) sits outside the index; ownerless suites are `night-owned`.
- Fixed-sleep polls (`tool-idea-wait-until`): ≈121 min/day estimated, the overshoot above measured; the tool waits
  until the overshoot outgrows what bash-cap's attach covers.
- `tests/affected` basename rule, no goal: 2 of 21,646 suite selections on 10-08…14. The 38 suites on 10-15 came
  from the new `docs/directions/` files before a suite named them (`docs/zz/README.md` still pulls 38).
- Expected gains have been inflated: on 10-14 the night expected 3,493 min/day from tests, while the whole tests
  row is ≈550. Price from the journal.

## Decisions

- 2026-10-16: audit reopens belong to the audit that makes them: `suite_audit` (an edit, load read as slower) here,
  `spend_audit` Spend's, `cpu_audit` System's. `green-once` dropped: ≈7 CPU-min/day after tests-once, for a cache.
- 2026-10-15: obsolete test checks belong to Legacy. («Updater doctor»)
- 2026-10-14: tests are the disease, the worker launch queue is protection: no goal shrinks a queue by launching
  less. («Updater doctor»)
- 2026-10-14: tests run once, when the work is done, and only where the change reaches: 72 suites for a one-file
  edit, with no catch to show for it, is a fault the night fixes. («Updater doctor»)
- 2026-10-14: a suite counts only while its owner waits on it, never while the owner generates beside it; a model's
  sleep or poll counts only past the end of what it awaits. Model-written scripts and our tools stay outside the
  index. («Updater doctor»)
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
- 2026-10-04: every wait (slot, queue, lock, poll) is journaled where the doctors read it and shown even when
  normal; the measuring itself adds no wait (10-06, «Чистка night run»). («make land for multiple workers in one
  repository»)
- 2026-10-03: speed never trades model, effort or thinking. («Updater doctor»)
- 2026-09-23: no serial machine-wide test queue: contention is met by lower priority (nice), and any hold tells the
  held chat and the menubar. («Updater doctor»)
