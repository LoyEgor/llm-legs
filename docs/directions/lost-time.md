# Tests and lost time (direction 2)

Wall-clock the harness adds to chats and workers (test runs and queues, slot waits, Bash-cap reruns, hook latency,
wrap-up, retries, usage walls) and tests' whole scope (Egor 2026-10-20): suites the full run leaves red, obsolete or
duplicate checks, and how tests are written.

## Metric

The Lost time index in the Doctors menu: overhead per unit of work against the previous 7 days, 1.00 unchanged; a
Paasche index over chat orders, worker tasks and night jobs (`time_budget.paasche`), read with `share/time_budget.py day
[--json]` (`index`, `index_window`). Per unit, so it shows health, not volume; one suite's honest number is CPU. It
judges goals on test cost and waits; muting targeted runs lowers it and says nothing about how tests are written.

Second number, proposed, Egor's word pending: test legacy lines standing in the four repositories by the helper-copy
and dead-test-unit methods (Recurring classes), read 7 days after a goal lands: 514 at HEAD 10-20 (copies 403, dead
units 111 at the 10-14 refresh). It judges goals on how tests are written (shared-asserts: the add-rate shows the
class stops coming back, this number that it moved); stale, covered and `uncaught:` checks join it once measured
(Open). Watched only: suites the last full run left red, code commits' rewrite share (the contract-checks trade).

### Baseline (computed 2026-10-20)

| | 10-06…12 | 10-13…18 (10-19 unsettled) |
|---|---:|---:|
| units: chat orders / worker tasks | 750 / 893 | 520 / 868 |
| min per order · chat / per task · workers | 2.13 / 12.57 | 1.05 / 16.78 |
| **Lost time index** | 1.00 | **1.26** (10-13…19 live: 1.09) |
| min/day: tests (running + queued) | 506 (505 + 78) | 259 (259 + 60) |
| min/day: waiting for workers · hooks and gates · usage walls · overshoot | 47 · 34 · 12 · 1 | 90 · 15 · 55 · 19 |
| min/day outside the index (`out_s.suites`) | 195 | 145 |
| suite runs/day · suite CPU-min/day (10-13…19) | 3,755 · 1,182 | 2,565 · 683 (2,350 · 647) |
| net test lines, four repositories (10-13…19) | +15,803 (+26,500 −10,697) | +9,367 (+14,447 −5,080) |
| code commits rewriting existing test lines (10-13…19) | 363 of 615, 59 % | 225 of 401, 56 % |
| test legacy lines (HEAD 10-20) · suites the last full run left red, red now | | 514 · 0 |

- Index and rows: `~/.cache/harness-doctor/budget-days/<day>.json` (`strata`, `rows`, `parts`, BUDGET_VERSION 5, all
  `settled`) summed per window over its days; index = Σ window overhead / Σ (window units × prior overhead per unit),
  per stratum, as `paasche`; rows are span unions, parts overlap. 10-19's worker rows sit in the account store this
  baseline may not read: 1.09 is `latest.json` → `speed.budget.index_by_day["2026-10-19"]` (10-20 01:40).
- The rise is workers': 10-13 (night 3131 closing: 9,930 overhead-min, 275 tasks) and usage walls (110 min on 10-18),
  while tests halved. Nights paused from 10-15 left 0–159 tasks a day: a mix change, unclear.
- Suites: `~/.cache/run-suites/runs.jsonl` by local day of `queued_at`, a run one entry of `suites`, CPU Σ `cpu_s`;
  decode with `json.JSONDecoder().raw_decode` (some lines hold two objects).
- Git rows: legacy.md's window ends and buckets. Rewrites: `git log --no-merges <end>..<next-end> --numstat`,
  each end `git rev-list -1 --first-parent --before='<day> 00:00' HEAD` (10-06, 10-13, 10-20 local). Not
  `--since/--until`, and not `--first-parent` on the log (that makes the first window 363 of 614). `local-config/`
  out, binary `-` skipped: a commit changing a code-bucket file that also deletes tests-bucket lines.

## Sources

- Index: `share/time_budget.py` over `~/.cache/harness-doctor/events/`, `waits`, worker-stats `runs.jsonl`, the
  run-suites journal. Suites: `runs.jsonl` (`worker_run`/`session` caller; `scope` direct, `named|changed`, full;
  `tree` digest from 10-09 21:14). Catches: `~/.cache/harness-doctor/test-catches.json` from 10-03.
- Full run: Close's `night-run suites`, every night, pilot ones too, in each repository's main checkout:
  `~/.cache/doctors/nights/<id>.json` `suites.repos[].failed`/`flaky` after one rerun, logs `<id>.suites.<repo>.log`;
  the next night's `jobs[]` of `kind` `suite`. No transcript: its reds are `unread`, never catches.
- `latest.json` → `speed.tests`; `share/suite_audit.py` `due()`; `suite:` rows of `share/spend-ledger.json` (removed
  never-red, vacuous or covered checks with their mutation; 38 on 10-13…14, full nights only); the harness ledger;
  dead test units: Code doctor `candidates.jsonl` (refresh 10-14).

## Recurring classes

Each was fixed as an instance and came back; harness-ledger rows as of 2026-10-16 unless named.

| class | rows | fixes | fix days | what makes it come back |
|---|---:|---:|---|---|
| a hook's latency is cut hook by hook | 64 | 64 (15 came back) | 09-29…10-10 | each hook is cut alone (dispatcher declined 10-05) |
| a slow suite is shaved one at a time | 57 | 76 (17 twice+) | 10-01…13 | one suite's seconds a fix; test_health files a suite again beside suite_audit |
| a run dies at the Bash cap or queues past it | 22 | 13 | 10-07…14 | Breakages' `bash-cap` |
| a suite idles on a fixed sleep or poll | 18 + 4 | 14 | 10-05…14 | each suite and model writes its own wait loop |
| a suite is reopened on a number not its own | 18 + 203 of 252 moved | 13 | 10-10…14 | a held rise read without load; `load()` 1.0 under 3 controls |
| a targeted run carries suites that never catch | 5 + 5 commits | 7 | 10-04…14 | each fix narrowed one rule; suites reached through a helper remain |
| a caller reruns a suite on content already green | 4 + 8e6961df | 2 | 10-10…14 | each caller decides alone; prose binds only its readers |
| a Close red is green before the night acts | 32 of 41 suite jobs | 9 merged | 10-05…14 | Close runs in the shared checkout under the night's load |
| each suite redefines its assert helpers | 22 of 41 suites added 10-09…15 | 1 fit round | 6 days | a new suite copies its preamble, helpers included |
| a code change rewrites checks pinning how code is written | 779 of 1,309 code commits 09-20…10-19 | | | below |

- Rows (`match.rule`/`ident`; fixes `fixes[]`, `regressed_at` = came back): hooks `hook_*` 57 + `floor` 7; shaving
  `test_slow|test_daily_cost|test_long_pole` 14 + `opportunity` `test-health/\(?(heavy|pole)` 43; reopened `suite:` rows
  whose `sources` blob ≠ `git rev-parse <end>:<path>` (`<end>` each repository's commit before 2026-10-17 00:00,
  llm-legs e13fb2357c57, ledger at that commit; HEAD today is 205): 203 + `regression` rows but `retests|targeted`; bash cap
  `test_hang` 13 + 8 `log_audit` + `tool-idea-run-all-attach`; idle `test-health/idle/*` 18 + 4 `log_audit`; green
  reruns `test-health/retests`, `/targeted`, `log_audit:landing-pipeline-retests-and-mistakes`.
- Weight 10-08…14: 37 % of targeted runs (22 % of their CPU, 265 of 1,210 CPU-min/day, raw 264.6) went to suites with
  no catch since 10-03. A run is caught when `basename(repo_root)/<suite stem without .sh>` is in any
  `test-catches.json` `days.*.catches` (through 2026-10-19); scope `named|changed`; `queued_at` local 10-08 through
  10-14. Retests 276 → 36 runs/day after tests-once; idle 6.3–7.8 min/day; hooks 156 → 20 min/day.
- Close reds, nights 10-04…14: 25 `green on main in the night rerun` (10-04's 231-min Close left 27), 5 green at press
  time, 2 nothing-to-do unexplained, 9 merged. In the logs: untracked files of the shared checkout
  (`test_claude_md_refs` 10-13 and 10-14 read `skills/.trash/…`), a chat's same-day fix (`test_report_frame_guard`
  10-07, 10-14), timing (`test_vendor_fingerprint` `65 -le 56`, `test_statusline_hooks`). The press-time check
  (`suite_green`) makes them free, so no goal moves Close to a detached `main` worktree (it would drop the
  untracked-file reds, 2 of 41); the full run takes 9–34 min a night since 10-05.
- Helper copies: `fail()`, `assert()`, `assert_fails()` bodies in tracked `*.sh` at column 0, `name()` line to brace
  balance, whitespace-stripped, `local-config/` out; every copy of a body seen twice or more, less one per body: 400
  at 10-16's ends, 403 at HEAD 10-20. Suites added 10-09…15 that define their own: `git log --first-parent
  --diff-filter=A --name-only --since=2026-10-09 --until=2026-10-16`, basename `test_*.sh`, a column-0
  `fail()`/`assert()`/`assert_fails()` in that commit's blob: 22 of 41 (llm-legs 13 of 23, claude-setup 7 of 13,
  review-bench 0 of 1, hammerspoon 2 of 4). Dead test units: `hammerspoon/tests/test_claude_keys_bin.sh` 111 (legacy.md
  class 2's method). Not a class: copied fixtures (shared 6-line blocks 2,901 lines over 309 pairs; no fix to return).
- Pinned checks (Egor's hypothesis 2026-10-19, measured 09-20…10-19): 60 % of code commits rewrite existing test
  lines (llm-legs 65 %, claude-setup 52 %, review-bench 49 %, hammerspoon 30 %), 0.23 lines per code line changed,
  median 5 (0.16) in a rewriting commit. Same rev-range, ends before 2026-09-20 and before 2026-10-20. Seeded sample
  of 10: that rewriting list in `git log` order (newest first), repos llm-legs, claude-setup, review-bench,
  hammerspoon, then `random.seed(20261020)` and `random.sample` (Python 3.11+): implementation 4 (f698194 a
  fixture copying internal files by name, 492e028 a wait on an internal lock path, 92aa785 a golden list of 76 problem
  ids and an exact fork list, f57b7c3 hook paths and reason strings), the suite's narrative PASS line only 1
  (630d45e), mixed 2 (48bfc77, cfda46d), behavior 3 (0eabdd9; 4c7bcb3 read as source text; 014f8ae one default in 7
  suites). 143 of 779 rewrite a PASS line, 21 only that; ten files hold 52 % of test-deletion lines (36,221;
  test_worker_run.sh 5,081 before its 10-01 split), llm-legs `tests/test_consistency.sh` 109 of those commits. Holds in part: 60 %,
  not 90 %; half the sample changed no behavior.

## Goals

Net
lines: `git diff --numstat <base>..<merge>` of the goal's commits, legacy.md's buckets, code and tests apart.
Breakages' `bash-cap`, this block's largest wait, is not repeated. Proofs replay fixed journals: a 7-day window
after landing moves with the pilot's volume (targeted suite CPU 1,210/day in 10-08…14, 113 on 10-15) and tests-once.

### goal suite-own-cost: a suite's cost has one queue, its rise read under load

Class: test_health's heavy and pole findings shave a suite again beside suite_audit's queue; a held rise is read
without load.
- Change, `share/suite_audit.py` `due()`: the held 2× rise read through `load()` as `jump()` is; under LOAD_CONTROLS
  `load()` reads unknown, never 1.0, the rise then on CPU a run (`test_health.cpu_run`). The source-edit reason stays:
  re-audits on an edit cut 13 of 61 suites to ≤ 0.65× wall a run (kept rows 0 of 15), ≈ 66 wall-min/day for 0.42 %
  of Claude spend (2026-10-20 night-cost research). `share/test_health.py` heavy and pole findings go.
- Proof, old → new on one `runs.jsonl`, `spend-ledger.json` and HEAD: heavy and pole findings on a suite suite_audit
  prices, before (unconfirmed; counted first) → 0; old and new `due()` differ only in rises the load explains. Not
  worse: in 7 days a risen suite (≥ 2× held over HELD_S) over the floor that is not due fails the goal. Net lines:
  code at most 0, the `load()` read against the heavy and pole findings that go.

### goal shared-asserts: suites take fail, assert and assert_fails from the lib they already source

Class: helper copies, llm-legs only (claude-setup's 8 and hammerspoon's 2 own-helper suites source no test lib).
- Change, `tests/lib/suite-journal.sh` between its `--lib` and `SUITE_JOURNAL_PID` returns (lines 272–274), so only
  a line-2 source gets them: the three in their commonest bodies, `assert` counting `asserts`. Copies in llm-legs,
  all lines of every copy of a body seen twice or more (not less one), tracked `*.sh`, `local-config/` out: 369, 158
  the three commonest (`fail` 40, `assert` 46, `assert_fails` 72); a copy behaving as the lib's goes, a variant stays.
- Proof: suites added in 7 days after landing defining their own helpers, the class row's add command: llm-legs
  13 of 23 in 10-09…15 → 0; the second number (Metric) falls by the copies that go. Not worse: every touched suite's
  PASS assert count against HEAD, its mutations still red. Net lines: tests below 0, up to −158 plus the lib's three.

## At night

- Section 2, Failed suites (README "The whole night"): one `suite` job per suite the newest earlier Close left red,
  nothing-to-do when green at press time. A pilot's `carry_list` prints only `pilot_goal`, so none; Close still runs.
- Change, `bin/night-run` `carry_list`'s pilot branch: when `pilot_goal` prints no goal line, no goal job is pending
  or live and no direction before `lost-time` in PILOT holds a `### goal`, it also prints the full night's `suite`
  lines: each night this block fronts the queue, after its last goal, before Close. `pilot_goal`'s break stays (a
  goal left here, failed or blocked ones retried nightly, keeps the next block waiting); with the goals Done the jobs
  stay (a returned section drops only by Egor's word).
- Its first night: each job merged with its red's cause named, or nothing-to-do with the cause read from the Close log;
  a suite red at two Closes running: 0; spend per job in the night header.

## Done

| date | change | result | evidence |
|---|---|---|---|
| 10-01 | `test_worker_run` (7,755 lines) split into 16 suites | slowest part 2,287 → 233 s | 8f113a19 |
| 10-04 | workers run only the covering suites (`tests/affected`) | | ad5d95f9 |
| 10-05 night 052f | slot admission, fixed sleeps cut, `test_instruction_gate` split in 8, hangs | median suite 160–240 → 35 s | c4adcbb8, 03001c01 |
| 10-13/14 nights | 252 suite audits (170 cut, 81 kept, 1 trade) | a pass 59 → 50 min, under noise, ×4.5 10-05's cost | `suite:` rows |
| 10-14 | tests lens, 10 heaviest suites, two rounds; lens tuned (review-bench 53f8137) | 131 fixes, +293 lines: cleanup is deletion only | 05a7238f, 62458120 |
| 10-14 | tests run once, when the work is done | runs per worker task 7.7 → 3.3, retests 276 → 36/day | 8e6961df |
| 10-23 | goal fan-out: suites with no catch in 90 days leave targeted runs but their own file's; Close red → green is a catch | `select()` replay, 218 commits 10-16…22: 5.70 → 4.96 wall-min a commit, CPU 5.54 → 4.96; watch: dropped suites red at Close over 7 nights, target 0 | 4e891fe3 |
| 10-23 | goal night-owned: stratum `night` (jobs of nights finished), one agent per night: hubs (`session`, `previous_sessions`, `wall` events'; 817e had 2, 3131 4) and Close (session-less `suites` runs inside it); an older settled day keeps its strata | v5 → v6, same journals 10-03…21: chat, workers equal 19/19 days; hub spans in `agents[None]` 0; `out_s.suites` 10-08…14 261 → 3.2 min/day (selfcheck + one 10 s run); night 6.12 → 5.87 min/job, index 1.09 → 1.09 | a92cc622 |

## Open

- Pinned checks, a trade. Cost: goal `contract-checks` rewrites the ten most-rewritten suites' checks to what a caller
  or Egor reads (exit, fields, the rendered menu) and the preamble's TESTS line asks for that, ≈10 worker runs. Loss:
  a rewrite can launder a regression (2026-07-25), and it moves no number here (model work, 2026-10-10); its proof is
  the rewrite share of those suites (target half, net lines ≤ 0, mutations red). Recommendation: the goal after
  shared-asserts, its rewrite share read beside the second number; `test_consistency.sh` stays (shared invariants).
- Covered and stale checks have no number: mutation runs, suite audits and the tests round run only in full nights.
  `uncaught:` first due 2027-01-01; 274 of 543 red→green episodes are `unread`, so silence can be a gap.
- `out_s.unmeasured` (426 → 2 min/day) stays outside; fixed-sleep polls (`tool-idea-wait-until`, ≈121 min/day est.)
  wait on `bash-cap`; `tests/affected` basename rule 2 of 21,646 (`docs/zz/README.md` still pulls 38); expected gains
  priced from the journal (10-14: 3,493 min/day expected, the whole row ≈550).

## Decisions

- 2026-10-20: everything about tests is one block, this one; Legacy is code only: tests grew and problems
  did not fall. («Updater doctor»)
- 2026-10-19: tests may mark only what changes with the code, so most changes rewrite them and the architecture must
  change: measure it. («Updater doctor»)
- 2026-10-16: audit reopens belong to their audit (`suite_audit` here, `spend_audit` Spend's, `cpu_audit` System's);
  `green-once` dropped, ≈7 CPU-min/day after tests-once.
- 2026-10-14 («Updater doctor»): tests are the disease, the worker queue protection: no goal launches less. Tests run
  once, when the work is done, only where the change reaches; a suite counts only while its owner waits on it. A new
  test only with a P1/P2 fix; a stale check deleted, never strengthened; a suite uncaught in 90 days deleted whole.
- 2026-10-13: speed is less delay, not less CPU: proven on wall minutes, CPU beside. («Updater doctor»)
- 2026-10-10/11 («test and lost time optimization»): Lost time is machine overhead around the work (tests, waits,
  hooks, refusals, walls), never work he chose, a wall-clock union from existing journals. The index has no norm, only
  the previous 7 days; never moves with volume, vendor, night or his presence.
- 2026-10-08: a chat's full `run-all` only on Egor's word (847c18ad). («Updater doctor»)
- 2026-10-07: pass reuse dropped for good; never shorten a race check's sleep; test cost audited every night, never
  trading quality. («Updater doctor») Concurrency judged by final speed. («Night run cleanup»)
- 2026-10-04/05 («make land for multiple workers in one repository»): every wait journaled where the doctors read it;
  measuring adds no wait. Hooks cut one by one, dearest first; a speed trade comes as min/day and share.
- 2026-10-03: speed never trades model, effort or thinking; 09-23: no serial machine-wide test queue (both «Updater
  doctor»).
- 2026-07-25: a rewritten check may assert the regression: diff each changed assertion against HEAD before trusting
  green (memory `worker-weakens-tests`).
