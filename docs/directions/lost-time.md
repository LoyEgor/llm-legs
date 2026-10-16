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
| min/day: wait overshoot (journal from 10-12) | | 12 |
| suite runs/day · suite CPU-min/day · CPU-min per unit | 3,613 · 1,281 · 7.5 | 4,922 · 1,456 · 5.2 |

- Method: strata, units and rows from `~/.cache/harness-doctor/budget-days/<day>.json` (`strata`, `rows`, `parts`,
  BUDGET_VERSION 5), summed over a window's days and divided by their count. Index = Σ window overhead / Σ (window
  units × prior overhead per unit), per stratum as `time_budget.paasche`. A row is the union of its parts' spans, so
  the bracketed parts overlap. Suite runs and CPU from `~/.cache/run-suites/runs.jsonl` by local day of
  `queued_at`: a run is one entry of a line's `suites`, CPU is Σ `suites.*.cpu_s`, per unit divides by chat orders +
  worker tasks (855; 1,952). Some lines hold two JSON objects: decode with `json.JSONDecoder().raw_decode`.
- `index_by_day` cannot recompute this baseline: it compares 7 days against 7 (the prior would reach 10-01, before
  the journals) and keeps only the last 7 days. Recompute from `budget-days/` as above.
- Live cross-check: the doctor's `index_window` at 10-16 19:51 (10-10…16 against 10-03…09) read 0.64.

## Sources

- Index, rows and waits: `share/time_budget.py`. It reads `~/.cache/harness-doctor/events/`, the worker-stats
  `runs.jsonl`, the run-suites journal and `~/.cache/harness-doctor/waits`. Settled days are kept in `budget-days/`.
- Suite runs, CPU, callers and trees: `~/.cache/run-suites/runs.jsonl`. `worker_run`/`session` give the caller,
  `kind`/`scope` say direct, targeted (`named|changed`) or full, and `tree` is a content digest from 10-09 21:14
  (hash reworked by 518a3523 on 10-13).
- Catches: `~/.cache/harness-doctor/test-catches.json` from 10-03, a caller's red → code edit → green; the night
  script has no transcript, so its full run's reds count as `unread`, never as catches.
- Test health: `latest.json` → `speed.tests` (`findings`, `fan_out`, `heavy`, `catches`), from `share/test_health.py`.
- Suite audits: `share/suite_audit.py` `due()`; rows `suite:` in `share/spend-ledger.json`; due ones are the
  `suite_audit` problems in `latest.json` → `speed.problems`, reason after `audit due:`.
- Ledger rows: `share/harness-ledger.json`, rules `opportunity` (test-health, `chat/tests`), `regression`, `test_*`,
  `tool_idea`, `wait_class` and the `log_audit` rows. Commits come from git.

## Recurring classes

Each class was fixed as an instance and came back. Ranked by ledger rows, as of 2026-10-16.

| class | rows | fixes | fix days | what makes it come back |
|---|---:|---:|---|---|
| a slow suite is shaved one at a time (heavy, pole, daily cost, long pole, slow) | 57 | 76 (17 rows twice+) | 10-01…13 | the cost is runs × wall and each fix cuts one suite's seconds; a pass went 59 → 50 min at ×4.5 the 10-05 cost |
| a suite is reopened on a number not its own: any edit of a source it shares, or wall read under load | 203 of 252 due + 18 | 13 | 10-10…16 | `due()` reopens on `spend.moved` (an edit) before any measured rise, and its 2× held rise is not load-matched |
| a run dies at the Bash cap or is queued past it (test_hang, log audit, `tool-idea-run-all-attach`) | 22 | 13 | 10-07…14 | Breakages' `bash-cap` |
| a suite idles on a fixed sleep or poll | 18 + 4 | 14 | 10-05…14 | each suite and model writes its own wait loop |
| a caller reruns a suite on content already green | 5 + 8e6961df | 4 | 10-10…14 | each caller (worker, chat, landing, night) decides alone; a prose rule binds only its readers |
| a targeted run carries suites that never catch | 5 + 5 commits | 2 + 5 | 10-04…14 | each fix narrowed one rule (ad5d95f9, 506ed8cc, 3e34ec7a, 477ffb74, ffcaf829); own suites with no catch remain |

- Row selection in `share/harness-ledger.json` (`match.rule`, `match.ident`; fixes = `fixes[]`, days = their `at`):
  - shaving: rules `test_slow`, `test_daily_cost`, `test_long_pole` (14) + `opportunity` idents matching
    `test-health/\(?(heavy|pole)` (43, `(heavy|idle)/…vendor_files` included).
  - reopened: `suite:` rows of `share/spend-ledger.json` whose `sources` blob differs from `git rev-parse
    HEAD:<path>` (203; `tests/lib/suite-journal.sh` moved in 160, the only moved source of 72) + every `regression`
    row but `test-health/retests` and `test-health/targeted`: 14 `fix/…` (8 fixes, 10-13…14; 11 are suite fixes,
    6 closed ruled-out as noise or load) and 4 `test-health/{pole,wait_night,wait_chat,idle}` volume rows (5 fixes).
    Live on 10-16 20:21, 102 of the 104 due over the 1 wall-min/day floor read `source changed`, none a slower run.
  - bash cap: `test_hang` (13 rows, 9 fixes) + 8 `log_audit` rows on the 10/25-min cap or slot queue (4 fixes) +
    `tool-idea-run-all-attach`.
  - idle: `opportunity` idents `test-health/idle/*` (18, 14 fixed, 10-10…14) + `time/wait_loop` and the `log_audit`
    rows `sleep-poll-loops-waiting`, `slot-throttle-foreground-sleeps`, `worker-suite-run-waits` (4, no fix); 10-05
    is the c4adcbb8 sleep cut, a commit with no row.
  - green reruns: `regression` and `opportunity` `test-health/retests`, `regression` `test-health/targeted`,
    `log_audit:known-red-suites-rediagnosed` (2 fixes), `log_audit:landing-pipeline-retests-and-mistakes`.
  - fan-out: `opportunity` `test-health/fan-out/*` (3, 2 fixes), `log_audit:tests-affected-over-selection`,
    `tool-idea-run-all-affected`.
- Measured weight, 10-08…14:
  - 36 % of targeted suite runs (22 % of their CPU, 272 of 1,210 CPU-min/day) went to suites with no catch since
    10-03: a suite is `basename(repo_root)/<stem>`, caught when it is a key of any `days.*.catches`.
  - Retests (a suite rerun on a (`repo_root`, `tree`) with an earlier `rc` 0): 276 runs/day, 84 CPU-min/day from
    10-09 21:14 to tests-once (10-14 15:42); 37/day, 7 CPU-min/day from then to 10-16 00:00.
  - Wait overshoot: 8, 34 and 38 min/day on 10-12…14 (`budget-days` `rows`); 32 on 10-14 waited on suites
    (`waits.on.suite`, bash-cap).
  - Idle findings (Σ `min_day` of class `idle` in `speed.tests.findings`, live): 6.3–7.2 min/day on 10-16.
- No goal for idle (little to gain; a race check's sleep stays) or green reruns (≈7 CPU-min/day after tests-once,
  and a cache would add code).
- The shaving class is the treadmill the goals below replace: they cut suite runs and audits, not seconds a run.

## Goals

The pilot night works these goals in order, one at a time. A goal that lands moves to Done with its commit and
proof. A goal that fails stays here with one line on what blocked it. Breakages' `bash-cap` is also this
direction's largest wait, and it is not repeated here.

### goal fan-out: a targeted run skips suites that have caught nothing

Class: targeted runs carry suites with no catch: 36 % of the runs and 22 % of the CPU in 10-08…14, after five
commits narrowed the selection one rule at a time.
- The change is in llm-legs `share/suite_select.py`. A suite with no catch in `CATCH_D` days, journaled for 7 days
  or more, leaves the targeted output unless it is itself a changed file. This is the `zero` set test_health's
  fan-out already computes. Close's full run still runs every suite.
- Test_health's fan-out finding then has nothing left to price, and its pricing code goes.
- Proof, old → new on the same machine: replay the 7 days before landing through the old and the new selector,
  using test_health's `fan_out` file mapping: targeted suite CPU-min/day (`kind` `suites`, `scope` `named|changed`;
  baseline 1,210, expected about −22 %). After landing, CPU-min per unit, 7 days against the 7 before.
- Missed catches come from the nightly full run, never from targeted runs (a dropped suite runs only there): a
  dropped suite red in a `scope` `full` run on a tree whose targeted runs passed, over 7 nights. Target 0; each is
  named, and one that is not a flake stops the goal.
- Must not get worse: the Lost time index; suite slot wait per suite run.

### goal audit-own-number: a suite audit comes due only on its own slower run

Class: a suite is reopened on a number not its own. 203 of 252 audited suites are due, 102 of the 104 over the floor
for `source changed` with no slower run; one shared helper edit reopened 160.
- The change is in llm-legs `share/suite_audit.py` `due()`. The `spend.moved` reason goes, with `changed_at`; the
  held 2× rise is read through `load()` as `jump()` already is. A suite is due only on a load-matched slower run,
  never audited, a new heavy suite or dead. Spend and System keep their own `spend.moved` callers.
- Proof, old → new from the same journals and ledger: run old and new `due()` over one `runs.jsonl`,
  `spend-ledger.json` and HEAD. Numbers: audits due a night (`suite_audit` problems; 104 on 10-16) and suites due
  with no slower run (102). Target: the second 0, the first only load-matched rises. After landing, suite-audit
  runs a night, 7 nights against the 7 before.
- Must not get worse: no suite gets slower unseen. Every suite whose `wall_floor` rose ≥ 2× over HELD_S in the
  replay window is due under the new rule, or is named with its `load()` ratio. And the Lost time index.

## Done

| date | change | result | evidence |
|---|---|---|---|
| 10-01 | `test_worker_run` (7,755 lines) split into 16 suites | slowest part 2,287 → 233 s | 8f113a19 |
| 10-04 | workers run only the covering suites (`tests/affected`) | | ad5d95f9 |
| 10-05 night 052f | slot admission, fixed sleeps cut, `test_instruction_gate` split in 8, answer-pty hang, slot_wait orphan race | median suite run 160–240 → 35 s at ×1 cost | c4adcbb8, 03001c01, 6389e500 |
| 10-08 | a chat's full `run-all` only on Egor's word | | 847c18ad |
| 10-10 | lifecycle, outcomes, consistency sharded | | |
| 10-13/14 nights | 252 suite audits (170 cut, 81 kept, 1 trade; `suite:` rows); on 10-13, 166 tests touched, 72 faster, 41 slower | a pass 59 → 50 min, below day-to-day noise, at ×4.5 the 10-05 cost | |
| 10-14 | tests run once, when the work is done | runs per worker task 7.7 → 3.3, retests 276 → 37/day; only 22 tasks so far | 8e6961df |

## Open

- Index coverage: suites with no owner (`out_s.suites`, 509 → 261 min/day, 46 % of the tests row) and `unmeasured`
  (426 → 2) sit outside the index, so a goal proven on it cannot see them.
- Fixed-sleep polls (`tool-idea-wait-until`) were estimated at ≈121 min/day; the measured overshoot is at most 38,
  most of it waiting on suites, which bash-cap's attach covers. The tool waits until the overshoot outgrows that.
- `tests/affected` basename rule: over the files changed on 10-08…14 it picked 2 of 21,646 suite selections. The 38
  suites on 10-15 came from the new `docs/directions/` files before a suite named them (`docs/zz/README.md` still
  pulls 38). It is no goal.
- Expected gains have been inflated: on 10-14 the night expected 3,493 min/day from tests, while the whole tests
  row is ≈550. Price from the journal and prove on the index.

## Decisions

- Speed never trades model, effort or thinking.
- Never shorten a sleep or timeout a race check depends on: the 10-05 cuts that did went vacuous and were reverted.
- The statusline refresh stays 3 s; only the per-render cost is cut.
- Tests run once, and a full `run-all` only on Egor's word.
- Obsolete test checks belong to Legacy.
- 2026-10-16: audit reopens belong to the audit that makes them: `suite_audit` (an edit, load read as slower) here,
  `spend_audit` Spend's, `cpu_audit` System's. `green-once` dropped: ≈7 CPU-min/day after tests-once, for a cache.
