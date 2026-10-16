# Legacy (direction 5)

Code and tests nothing needs: dead code, duplicates, and obsolete or duplicate test checks.

## Metric

Legacy lines standing in the four sweep repositories (llm-legs, claude-setup, review-bench, hammerspoon): the
recurring classes' "lines now" summed by their methods, tests apart, read 7 days after the last goal lands (class 2
at a `code-doctor refresh` the reader runs). Another direction moves it only by adding legacy. A test check leaves
only when stale (it guards a case the code can no longer produce), covered (another suite's check fails on the same
mutation), or in a suite that caught no defect in 90 days, deleted whole (`uncaught:`, Decision 2026-10-14).

Net lines stay observed, never a verdict (Decision 2026-09-30): weekly churn moves them ±11k, more than every goal
here, and other directions' goals add lines, which README's worse → revert would charge to Legacy.

### Baseline (computed 2026-10-16)

Legacy lines: **3,966** (tests 512): class 1 2,852, class 2 683 (10-14 refresh), class 3 401, class 4 30.

| net lines, four repositories | 10-02…08 | 10-09…15 |
|---|---:|---:|
| **code** | **+27,340** (+38,415 −11,075) | **+16,153** (+26,728 −10,575) |
| **tests** | **+22,102** (+48,658 −26,556) | **+12,675** (+24,864 −12,189) |
| data: ledgers, `limits.json`, plists (own line) | +6,200 | +15,229 |
| docs, `*.md` (own line) | +478 | +376 |

- Method (git covers both windows whole: 7 full days each):
  - A window's ends are each repository's commit `git rev-list -1 --first-parent --before='<day> 00:00' HEAD` for
    10-02, 10-09 and 10-16, local time. Lines are `git diff --numstat` between two ends, binary files skipped.
  - Buckets by path: tests = under a `tests/` or `test/` dir, or a `test_*` file; docs = `*.md`; data =
    `*.json|jsonl|plist|txt|log|csv|yaml`; code = the rest.
  - The ends: llm-legs 5e6a2951 af820ec9 916f78d6, claude-setup 64135192 2f02e870 dcd60c0f, review-bench bfe77bbb
    9dda0c3e 69c02d3d, hammerspoon fb9aa82b 31c703ac 0eabdd90.

## Sources

- Code doctor (`~/.cache/code-doctor/`, last refresh 2026-10-14 12:19): `latest.json` (counts by group, yield),
  `candidates.jsonl` (549 candidates with files and units), `verdicts.json`, `judge-runs.jsonl`, `accounting.jsonl`.
  Pilot nights run no refresh, judge or Code fixer (`bin/night-run` PILOT_RULES).
- `share/code-ledger.json`: the Code doctor's 9 dead and duplicate rows, all fixed-pending, −424 lines 10-03…10-13.
- llm-legs `bin/harness-doctor` `DEPLOYS`: every copy llm-legs installers deploy, its source, kind and installer.
- `share/spend-ledger.json` `suite:` rows: each Suite audit's removed never-red, vacuous or covered checks, with the
  mutation that proves it; 38 audits did so on 10-13…14. Full nights only: a pilot night launches no audit.
- `share/harness-ledger.json`: no legacy rule. None of its 105 log-audit rows is about dead or duplicate code.

## Recurring classes

Ranked 2026-10-16 by lines, from the ledgers, the Code doctor's candidates and git from 10-02 to 10-15. Each class
was fixed as an instance and came back.

| class | rows | days seen | instances fixed | lines now |
|---|---:|---:|---:|---:|
| 1. deployed copies: `night-snapshot` commits what a sweep repository deploys into claude-setup `local-config/home` | 111 Code doctor candidates | 2/2 since 10-13 | 3 | 2,852 in 22 files |
| 2. a removal leaves its other end: a retired feature's readers, flags, tests and prose, a deleted reader's writer, a unit the removal orphaned | 42 dead candidates, 5 code-ledger dead rows, 2 check refusals | 10 (10-03…10-13) | 5 ledger fixes (−252) + 9 relay commits | 683 dead lines waiting |
| 3. each suite redefines its assert helpers: `fail` defined 190 times (one body 74 times), `assert` 101 (50), `assert_fails` 40 | 25 of 45 suites added 10-09…15 | 6 | 1 fit round (10-14) | 401 |
| 4. every new tool rolls its own helpers (JSON IO, bounded runs) | 4 code-ledger rows | 5 (10-08…10-14) | 4 + 3 fit-round folds | 30 |

- Method of the table, at HEAD on 2026-10-16:
  - class 1: `git ls-files local-config/home` at a `DEPLOYS` target (21 files, 2,818 lines), plus files byte-equal
    (`cmp`) to a tracked llm-legs or hammerspoon file (hammerspoon's `com.egor.hammerspoon.plist`, 34); `wc -l`;
  - class 2: dead lines = `lines` of the units the 42 `dead` rows of `candidates.jsonl` name as dead in `detail`
    (`X is defined and never called`, `no entry point reaches X, Y`), each once; the `is N lines with N branches`
    units (worker-run, instruction-files.sh: 11,534) and clone-only units (24) are out; `value` adds a clone signal: 695; days = the dead-row fixes, relay sweep, stamp and refusals; relay commits = `git log
    --first-parent -i -E --grep='^relay (leftovers|cleanup)|^relay-free polish|retired relay|dangling worker-relay'`
    from 10-09 on, less two Spend audits (fc86109c, 3e8062e0);
  - class 3: `fail()`, `assert()`, `assert_fails()` bodies in tracked `*.sh`, defined at column 0, from the `name()`
    line to the line where `{`/`}` balance (one body closes on `exit 1; }`), whitespace-stripped; lines = every copy
    of a body seen twice or more, less one per body; suites added = `tests/` files added on first parents, by date;
  - class 4: `def read_json(`, `def read_jsonl(`, `def write_json(`; lines = per repository, every body less the
    longest per name, less the copies the code ledger keeps on purpose (chat-load: deployed beside memlogd;
    harness-doctor's `read_jsonl`: a binary tail reader; review-anchors: a standalone script);
  - classes 3–4 leave `local-config/` out;
  - shared 6-line blocks: windows of 6 non-blank lines, whitespace-stripped, found in two or more tracked test
    files (the Method's tests bucket, text files at HEAD 96f8c2da, 164,745 lines); a pair (A, B) counts A's
    non-blank lines inside windows it shares with B, A the alphabetically first path; the total sums the pairs.

Why they come back:
1. The snapshot (d2ecaa0, 10-13) copies every file in `~/.local/libexec` and every agent plist naming it. Installers
   deploy llm-legs files there, because launchd cannot run a program off /Volumes/Work. `DEPLOYS` already lists each
   copy with its installer and heals drift (`harness-doctor --redeploy`); the snapshot does not read it.
   - 3 of the 10 libexec copies have drifted. Fixes to them do not last: a fit round synced store-lock.sh (1eaff59),
     a legacy round deleted ipad-mic-refresh (091c455), test_report_frame_guard gained an exemption (2612a804).
   - The Code doctor's judge spent all 16 verdicts of 10-14 (247k tokens) on these copies.
2. A retirement spans repositories while each commit is one, and the Code fixer may not finish its own.
   - Relay: retired 10-09 (ee185fa8, 46879c6). Its leftovers took 9 commits in 3 repositories, all but one on 10-09.
   - Delegated stamp: its reader went in review-bench 6a684df. The writers went 10-08 (7d353f02, fa10c66), the
     prose and a test block 10-12 (8090aa7).
   - `code-doctor check` refuses a Code fixer's deletion that no judged problem names, even of a unit the same run
     orphaned: normalizeDir stayed dead (10f7f32, 10-07), and the statusline.sh and grokb `run_bounded` migrations,
     green, were reverted (84de7cc5, 10-13).
   - The Code doctor finds leftovers nights later and fixes 1 cause a day (yield 424 lines for 6.0M tokens, under
     `LOW_YIELD_PER_KTOK`, so `queue_k` = `TOP_K_LOW_YIELD` = 1); its judge takes 8–16 candidates a night under a
     400k token cap, so the queue grew from 109 pending (10-03) to 531 waiting (10-14).
   - Audits of retired components (spawn:codex-worker, spawn:review-waiter 10-10; cd-guard ×4 10-13) are Spend's:
     `due()` reopens a cut whose tail is still in the 7-day window (spend.md class 1, goal audit-due).
3. A new suite copies its preamble, helpers included (6 splits since 10-03 netted only +18…+73 each over a shared
   harness). Every llm-legs suite already sources `tests/lib/suite-journal.sh` on line 2.
4. A new tool starts standalone, and a deployed copy (chat-load) cannot import `share/`. Each fold fixes one helper.
   REUSE FIRST in worker-run's brief preamble has asked for reuse since 09-18; the class came back anyway.

Checked, not a class:
- Copied fixtures across split suites: shared 6-line blocks total 2,901 lines over 309 pairs (2,472 distinct
  lines: an upper bound), the largest pair test_codexb/test_geminib with 108. No fix of one exists to have come back.
- Readers of retired experiments: none of the 5 tags removed since 09-20 has one left (grep outside docs/handoffs).
- Names a retirement left in code or tests at its own commit, 10-09…15: of 103 commits deleting a file or
  definition, 2 (worker-corpus's frame-guard exemption, 138b5a6c; `words_grant_target` in a planted test, b50e5bff).
  Other hits were common words, variables, keys, an 8-second cross-repository pair, and 234256e0, which swept in a
  staged deletion a minute before its retirement (6280c424): a scan of deleted names would list mostly false hits.
- The rest of the test growth is new suites for new code: test_test_health, test_tool_mining, test_log_stores…

## Goals

The pilot night works these goals in order, one at a time. A goal that lands moves to Done with its commit and proof.
A goal that fails stays here with one line on what blocked it.

### goal deployed-copies: the machine snapshot leaves out what a sweep repository deploys

Class 1.
- Where: claude-setup `bin/night-snapshot` and `bin/restore-local`, reading `DEPLOYS` as the one list (no second
  list, no byte or name matching): `harness-doctor --deploys` prints each copy's home path and its group's installer
  (`cp <source>` for a hand copy).
  - `night-snapshot` leaves out every listed path; `restore-local`, once llm-legs is cloned, runs each installer
    instead of copying, then starts the agents as now.
  - The 21 copies leave the tree, with test_report_frame_guard's local-config skip; the hammerspoon plist stays.
- Proof, on each night's snapshot commit for 7 days after landing: lines under `local-config/home` by class 1's
  method, a copy a new deployer adds included: 2,852 in 22 files → 34 (the plist). Code doctor duplicate candidates
  with a `local-config/` file: 111 of 247 → 0, at a `code-doctor refresh` the measurer runs.
- Must not get worse: `restore-local` into a scratch `HOME`, `launchctl` stubbed on `PATH` (installers bootstrap the
  real `gui/$UID` whatever `HOME` says), restores today's file set under `.local/libexec` and `Library/LaunchAgents`;
  the live `~/.local/libexec` is only read.

### goal shared-asserts: suites take fail, assert and assert_fails from the lib they already source

Class 3.
- Where: llm-legs `tests/lib/suite-journal.sh`, between its `--lib` and `SUITE_JOURNAL_PID` returns (lines 272–274),
  so only a suite's line-2 source gets them: the runner (its own `fail` exits 4), the statusline scripts and
  claude-setup's suites source `--lib`.
  - It defines the three helpers in their most common bodies, `assert` counting `asserts` as the copies do.
  - Every identical copy in llm-legs goes: 372 lines. A variant stays where it behaves differently; suites sourcing
    `--lib` or nothing keep theirs.
- Proof: suites added in the 7 days after landing that define their own `fail`, `assert` or `assert_fails`, by class
  3's method: llm-legs 15 of 26 in 10-09…15 → 0.
- Must not get worse: every touched suite's PASS assert count against HEAD, its mutations still red.

### goal own-orphans: a Code fixer deletes what its own change orphaned

Class 2 (Decision 2026-10-09: change impact).
- Where: llm-legs `bin/code-doctor` `check` (bin/code-doctor:3464–3476).
  - A deletion no judged problem names passes when every reference to the unit at the run's base sits in lines the
    same run deletes, its own definition aside, or the unit is a copy whose callers the run moved to a shared one.
  - Every other unjudged deletion stays refused.
- Proof, old → new on this machine: replay both refusals in scratch worktrees (10f7f32 plus normalizeDir's deletion;
  84de7cc5 plus the statusline.sh and grokb migrations): old `check` refuses both, new passes both, both refuse a live
  unit. Then, in full nights once the queue empties, Code fixer rows noting a unit left or a migration reverted for
  an unjudged deletion: 2 of 9 (10-03…10-13) → 0.
- Must not get worse: no unit `check` passes keeps a `git grep -w` hit outside the run's deleted lines in the four
  trees; `doctor-fix close` time for a Code run.

## Done

- Retired features took their tests with them: llm-legs `test_light_edit`, `test_land`, `test_worktree`,
  `test_night_report_trial`; claude-setup 5 files.
- 10-14: a tests lens pilot on the 10 heaviest suites ran two rounds (05a7238f, 62458120): 131 fixes, +1,096 −803 =
  +293 lines. The lens as it stands strengthens weak checks, which adds lines, so cleanup here is deletion only.
- 10-14: the lens was tuned (review-bench 53f8137, 051aa8f); a tests round joined the debt pass (9e852e4d), unrun.

## Decisions

- 2026-10-15: the harness's code and tests shrink, not grow; obsolete tests are Legacy's. («Updater doctor»)
- 2026-10-14: unused code is deleted together with its tests, with no "Egor asked" marker; what he wants kept, he
  asks a test for. («Updater doctor»)
- 2026-10-14: a new test comes only with a P1/P2 fix, written without his word. («Updater doctor»)
- 2026-10-14: a stale check is deleted, never strengthened. («Updater doctor»)
- 2026-10-14: a suite that caught no defect in 90 days is deleted whole (`uncaught:` in doctor-fix's suite audit).
  («Updater doctor»)
- 2026-10-13: legacy sits in long-settled code, not in review debt: debt neither scopes nor measures it.
  («Updater doctor»)
- 2026-10-13: a mechanism is not worth a heap of new lines; nights adding ~1,500 lines each are the problem.
  («Token spending tracking and optimization»)
- 2026-10-12: a rename keeps no alias for an old name nothing used. («Token spending tracking and optimization»)
- 2026-10-10: Haiku runs the legacy lens only chunked and with an Opus judge. («Updater doctor»)
- 2026-10-09: legacy is judged by whether the code is needed, not by whether it has callers, and includes change
  impact: what a landed change made obsolete, directly or indirectly. («Updater doctor»)
- 2026-10-01: the sweep repositories land everything in main; nothing is kept back on a list. («Updater doctor»)
- 2026-09-30: removal is asked for in prose in briefs, never by a gate or mechanism that pushes a model to delete;
  net lines are only observed. («Updater doctor»)

## Open

- Covered and stale checks standing have no number: it needs mutation runs, and their sources, Suite audits and the
  tests round (Debt, paused), run only in full nights.
- `uncaught:` is first due 2027-01-01 (the journal starts 10-03). 274 of 543 red→green episodes so far are `unread`
  (no transcript, `share/test_catches.py` `judge`) and never count as a catch, so a suite's silence can be a gap.
- Change impact beyond code and tests (2026-10-09): hooks, docs and actions a landed change made obsolete. No class
  or goal counts them.
