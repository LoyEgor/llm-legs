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
and dead-test-unit methods, read 7 days after a goal lands: 514 at HEAD 10-20 (copies 403, dead
units 111 at the 10-14 refresh). It judges goals on how tests are written; stale, covered and `uncaught:` checks
join it once measured (Open). Watched only: suites the last full run left red, code commits' rewrite share (the contract-checks trade).

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
  baseline may not read: 1.09 is `latest.json` → `speed.budget.index_by_day["2026-10-19"]`.
- The rise is workers' (night 3131 closing on 10-13: 9,930 overhead-min, 275 tasks; walls 110 min on 10-18) while
  tests halved; paused nights left 0–159 tasks a day from 10-15: mix, unclear.
- Suites: `~/.cache/run-suites/runs.jsonl` by local day of `queued_at`, a run one entry of `suites`, CPU Σ `cpu_s`;
  decode with `json.JSONDecoder().raw_decode` (some lines hold two objects).
- Git rows: legacy.md's window ends and buckets. Rewrites: `git log --no-merges <end>..<next-end> --numstat`,
  each end `git rev-list -1 --first-parent --before='<day> 00:00' HEAD` (10-06, 10-13, 10-20 local); `local-config/`
  out, binary `-` skipped: a commit changing a code-bucket file that also deletes tests-bucket lines.

## Sources

- Index: `share/time_budget.py` over `~/.cache/harness-doctor/events/`, `waits`, worker-stats `runs.jsonl`, the
  run-suites journal. Suites: `runs.jsonl` (`worker_run`/`session` caller; `scope` direct, `named|changed`, full;
  `tree` digest from 10-09 21:14). Catches: `~/.cache/harness-doctor/test-catches.json` from 10-03.
- Full run: Close's `night-run suites`, every night, pilot ones too, in each repository's main checkout:
  `~/.cache/doctors/nights/<id>.json` `suites.repos[].failed`/`flaky` after one rerun, logs `<id>.suites.<repo>.log`;
  the next night's `jobs[]` of `kind` `suite`. No transcript: its reds are `unread`, never catches.
- `latest.json` → `speed.tests`; `share/suite_audit.py` `due()`; `suite:` rows of `share/spend-ledger.json` (removed
  never-red, vacuous or covered checks with their mutation; full nights only); the harness ledger;
  dead test units: Code doctor `candidates.jsonl` (refresh 10-14).

## Recurring classes

Each was fixed as an instance and came back; harness-ledger rows as of 2026-10-16 unless named.

| class | rows | fixes | fix days | what makes it come back |
|---|---:|---:|---|---|
| a hook's latency is cut hook by hook | 64 | 64 (15 came back) | 09-29…10-10 | each hook is cut alone (dispatcher declined 10-05) |
| a run dies at the Bash cap or queues past it | 22 | 13 | 10-07…14 | Breakages' `bash-cap` |
| a suite idles on a fixed sleep or poll | 18 + 4 | 14 | 10-05…14 | each suite and model writes its own wait loop |
| a Close red is green before the night acts | 32 of 41 suite jobs | 9 merged | 10-05…14 | Close runs in the shared checkout under the night's load |
| a code change rewrites checks pinning how code is written | 779 of 1,309 code commits 09-20…10-19 | | | below |

Settled by Done goals: suite shaving and reopening, never-catching suites, helper copies; green reruns are 0.2 % of
worker suite-seconds 10-16…22 (7.4 % 10-09…15).
- Rows (`match.rule`/`ident`; fixes `fixes[]`, `regressed_at` = came back): hooks `hook_*` 57 + `floor` 7; bash cap
  `test_hang` 13 + 8 `log_audit` + `tool-idea-run-all-attach`; idle `test-health/idle/*` 18 + 4 `log_audit`. Idle
  6.3–7.8 min/day; hooks 156 → 20 min/day.
- Close reds, nights 10-04…14: 25 green in the night rerun, 5 at press time, 2 unexplained, 9 merged (untracked
  files, same-day fixes, timing); the press-time `suite_green` makes them free, so Close stays in the main checkout
  (a detached worktree drops 2 of 41 reds); the full run takes 9–34 min a night since 10-05.
- Helper copies: `fail()`, `assert()`, `assert_fails()` bodies in tracked `*.sh` at column 0, `name()` line to brace
  balance, whitespace-stripped, `local-config/` out; every copy of a body seen twice or more, less one per body: 403 at
  HEAD 10-20. Suites added 10-09…15 that define their own (the class command): `git log --first-parent
  --diff-filter=A --name-only --since=2026-10-09T00:00Z --until=2026-10-16T00:00Z` (a bare date takes now's clock),
  basename `test_*.sh`, a column-0 helper in that commit's blob: 22 of 41 (llm-legs 13 of 23). Dead test units:
  `hammerspoon/tests/test_claude_keys_bin.sh` 111 (legacy.md class 2's method).
- Pinned checks (Egor's hypothesis 2026-10-19, measured 09-20…10-19): 60 % of code commits rewrite existing test
  lines (llm-legs 65 %, hammerspoon 30 %), 0.23 lines per code line changed.
  Sample of 10 (`random.seed(20261020)`): implementation 4, PASS line only 1, mixed 2, behavior 3. 143 of 779 rewrite
  a PASS line, 21 only that; ten files hold 52 % of test-deletion lines, `tests/test_consistency.sh` 109 commits. Holds
  in part: 60 %, not 90 %; half the sample changed no behavior.

## Goals

Net
lines: `git diff --numstat <base>..<merge>` of the goal's commits, legacy.md's buckets, code and tests apart.
Breakages' `bash-cap`, this block's largest wait, is not repeated. Proofs replay fixed journals: a 7-day window
after landing moves with the pilot's volume and tests-once.

### goal walled-resume: a walled worker's rescue continues its session

Class: usage walls 10-09…22, claudeb 1,054 worker-min (75/day), codex 117. `reroute_walled` (`bin/worker-run`,
10-05) restarts a walled claudeb run fresh, redoing the walled attempt; the 07-25 rotation cut's rescue was `RESUME
<session>` on a worker-pick account; every profile's `projects` links `~/.claude/projects` (its "one profile"
comment is wrong).
- Change: a claudeb rescue resumes the walled session on the picked account (one reroute; `REROUTE:` and the
  browser, `.resume`, explicit-account refusals stay); of the stale-RESUME refusal only `RESUME_CONTEXT_CAP` (150k)
  stays, past it the rescue starts fresh; `run_split` counts its relaunch gap.
- First step: the 10-19 rescues (walled 9,505–9,520 s; 2,740, 8,354, 8,424 s) repeat the walled sessions' calls, a
  finished session resumed on another account answers, and the walled ones (≈2.6 h, cache missed there) resume under
  the cap and the fresh rescues' 2.7–6.9M tokens; any fails, stop.
- Proof, old → new: run dirs start 10-14; 10-14…22, 4 rerouted claudeb runs walled ≥ 10 min: 516 min, fresh rescues
  338, redo ≤ 338 (≈38 worker-min/day); 10-09…13's 9 runs (288 min) have no recorded source. New, 14 days after
  landing: each rescue under the cap keeps the walled session id, its walled minutes only relaunch gaps.
- Must not get worse: rescues succeed (old rate unconfirmed); rescue tokens a walled run at or under the fresh
  rescues' (tokenmap, counted first); codex walls untouched.

### goal chat-owned: the chat stratum counts only Egor's own turns

Class: a caller the index does not own. Since 8bfaa17f (10-09) a day fix launch opens a chat on `Fix orchestrator:
read …`, which `C1_MACHINE` (`bin/harness-doctor`) misses: 4 chats, 279 turn-span min on 10-20 (10-09…22: 10-09,
10-14, 10-20 only). `read_transcript` never reads `forkedFrom`: 494 owner text-prompt rows repeated by uuid 10-12…20
(a row broader than C1's, unconfirmed).
- Change: `C1_MACHINE` takes `Fix orchestrator:`, drops `Doctor fixer run` (no emitter; `vendor-fingerprint` still
  prints `Vendor release event` with no night); `read_transcript` skips `forkedFrom` entries;
  `time_budget.night_agents` owns a doctor-fix run record's `session` (no `night`) as a night agent, units its runs
  closed that day.
- Proof: a settled day keeps its cached strata but `out_s` (`share/time_budget.py`), so v6 → v7 is an uncached
  `budget()` replay of 10-09…22: 10-20 chat 7.0 → ≈3.8 min an order (607 − 279 min, 87 orders; fork rows
  unconfirmed); night owns 10-20's 51 doctor-fix records (minutes unconfirmed); workers equal every day; live from
  10-23. Gain 0 minutes, a true compass.
- Must not get worse: no orchestrator span in `agents[None]` or `out_s`; a settled day keeps its strata.

Dropped, 10-09…22: full-night slot queues (917 worker-min/day), memory and load; run-suites `limit` waits (CPU busy
in all 88 samples); 10-20's 63 fixers, CPU-bound, fan-out's; chats testing while iterating (13 min/day, a rule
exists); chat compaction 19.6 min/day, a spend trade; worker compaction 3.6 min/day; API retries 7; model-written
scripts, beside the index.

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
| 10-05 night 052f | slot admission, fixed sleeps cut, `test_instruction_gate` split in 8, hangs | median suite 160–240 → 35 s | c4adcbb8, 03001c01 |
| 10-13/14 nights | 252 suite audits (170 cut, 81 kept, 1 trade) | a pass 59 → 50 min, under noise, ×4.5 10-05's cost | `suite:` rows |
| 10-14 | tests lens, 10 heaviest suites, two rounds, lens tuned | 131 fixes, +293 lines: cleanup is deletion only | 05a7238f, 62458120, review-bench 53f8137 |
| 10-14 | tests run once, when the work is done | runs per worker task 7.7 → 3.3, retests 276 → 36/day | 8e6961df |
| 10-23 | goal fan-out: suites with no catch in 90 days leave targeted runs but their own file's; Close red → green is a catch | `select()` replay, 218 commits 10-16…22: 5.70 → 4.96 wall-min a commit, CPU 5.54 → 4.96; watch: dropped suites red at Close over 7 nights, target 0 | 4e891fe3 |
| 10-23 | goal night-owned: stratum `night` (jobs of nights finished), one agent per night: its hub sessions and Close's session-less runs | v5 → v6, journals 10-03…21: chat, workers equal 19/19 days; hub spans in `agents[None]` 0; `out_s.suites` 10-08…14 261 → 3.2 min/day; night 6.12 → 5.87 min/job | a92cc622 |
| 10-23 | goal suite-own-cost: test_health's heavy and pole findings go; both suite_audit rises read beyond `load()`, on CPU a run under 3 controls | heavy/pole rows on audited suites, 4 windows, 12 → 0; at-once rises at flat CPU (2 controls) 3 → 0, due 60 → 60; code −20, tests −12 lines; 7-day read: a suite risen beyond its load or CPU (≥ 2× held over HELD_S) not due, target 0 | ebf5bde1 |
| 10-23 | goal shared-asserts: `fail`, `assert`, `assert_fails` from `tests/lib/suite-journal.sh` to line-2 sources; 133 copies behaving as the lib's go, variants stay | llm-legs helper-copy lines 382 → 182 (less one 333 → 145); touched suites' PASS counts = HEAD's, 3 sampled mutations red; tests −188 lines; 7-day read: suites added defining their own (class command), llm-legs 13 of 23 → target 0 | 5e084b8d |

## Open

- Pinned checks, a trade. Cost: goal `contract-checks` rewrites the ten most-rewritten suites' checks to what a caller
  or Egor reads (exit, fields, the rendered menu) and the preamble's TESTS line asks for that, ≈10 worker runs. Loss:
  a rewrite can launder a regression (2026-07-25), and it moves no number here (model work, 2026-10-10); its proof is
  the rewrite share of those suites (target half, net lines ≤ 0, mutations red). Recommendation: next after this
  file's goals, its rewrite share read beside the second number; `test_consistency.sh` stays (shared invariants).
- Code's moved `tests/<repo>/<label>` rows (`moved_opportunities`): a third suite-cost queue, 0 live 10-23.
- Index 0.10 (10-16…22) is mix: the prior window's slot queues (workers 19.7 → 1.3 min a task), 10-22's 631 judge
  calls of 0.3 min (0.17 without); a work-sized worker unit is open.
- Covered and stale checks have no number: mutation runs, suite audits (65 due on 327 suite-min/day, none since 10-14
  but 10-20's 8) and the tests round run only in full nights. `uncaught:` first due 2027-01-01; 274 of 543 red→green episodes are `unread`, so silence can be a gap.
- `out_s.unmeasured` (426 → 2 min/day) stays outside; fixed-sleep polls (`tool-idea-wait-until`, ≈121 min/day est.)
  wait on `bash-cap`.

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
