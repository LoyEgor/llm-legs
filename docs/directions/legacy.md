# Legacy (direction 5)

Code nothing needs: dead code and duplicates. Tests, obsolete and duplicate checks included, are Tests and lost
time's ([lost-time.md](lost-time.md), Egor 2026-10-20); a removal here still takes its own tests with it.

## Metric

Legacy lines standing in the four sweep repositories (llm-legs, claude-setup, review-bench, hammerspoon): the
recurring classes' "lines now" summed by their methods, code only (no line under a `tests/` or `test/` dir or in a
`test_*` file), read 7 days after the last goal lands (class 2 at a `code-doctor refresh` the reader runs). Another
direction moves it only by adding legacy.

Net lines stay observed, never a verdict (Decision 2026-09-30): weekly churn moves them ±11k, more than every goal
here, and other directions' goals add lines, which README's worse → revert would charge to Legacy.

### Baseline (computed 2026-10-20, code only)

Legacy lines: **3,518**: class 1 2,916 in 26 files (HEAD 2026-10-20, unchanged since 10-16), class 2 572 (the 10-14
refresh, the last; its 111 test lines, `hammerspoon/tests/test_claude_keys_bin.sh`, are Tests and lost time's), class
3 30 (HEAD). The 10-16 figure was 4,030 with tests 512 (class 2's 111 + the assert helpers' 401, now lost-time.md's).

| net lines, four repositories | 10-06…12 | 10-13…19 |
|---|---:|---:|
| **code** | **+15,733** (+27,534 −11,801) | **+15,712** (+19,886 −4,174) |
| data: ledgers, `limits.json`, plists (own line) | +9,011 | +9,591 |
| docs, `*.md` (own line) | +175 | +1,785 |

- Method (git covers both windows whole: 7 full days each; the tests bucket is lost-time.md's):
  - A window's ends are each repository's commit `git rev-list -1 --first-parent --before='<day> 00:00' HEAD` for
    10-06, 10-13 and 10-20, local time. Lines are `git diff --numstat` between two ends, binary files skipped.
  - Buckets by path: tests = under a `tests/` or `test/` dir, or a `test_*` file; docs = `*.md`; data =
    `*.json|jsonl|plist|txt|log|csv|yaml`; code = the rest.
  - The ends: llm-legs 31652cc4 419d60e8 e93902c2, claude-setup 5dc53083 bd436c1f d3aa368f, review-bench 46543731
    b2d851be 21a08465, hammerspoon 01153ba2 5d953cf3 f1872c3a. The same method on 10-02/09/16's ends reproduces the
    10-16 table (code +27,340 → +16,153).

## Sources

- Code doctor (`~/.cache/code-doctor/`, last refresh 2026-10-14 12:19): `latest.json` (counts by group, yield),
  `candidates.jsonl` (549 candidates with files and units), `verdicts.json`, `judge-runs.jsonl`, `accounting.jsonl`.
  Pilot nights run no refresh, judge or Code fixer (`bin/night-run` PILOT_RULES).
- `share/code-ledger.json`: the Code doctor's 9 dead and duplicate rows, all fixed-pending, −424 lines 10-03…10-13.
- llm-legs `bin/harness-doctor` `DEPLOYS`: every copy llm-legs installers deploy, its source, kind and installer.
- `share/harness-ledger.json`: no legacy rule. None of its 105 log-audit rows is about dead or duplicate code.

## Recurring classes

Ranked 2026-10-16 by lines, from the ledgers, the Code doctor's candidates and git from 10-02 to 10-15; lines now
recomputed 2026-10-20, code only. Each class was fixed as an instance and came back.

| class | rows | days seen | instances fixed | lines now |
|---|---:|---:|---:|---:|
| 1. deployed copies: `night-snapshot` commits what a sweep repository deploys into claude-setup `local-config/home` | 111 Code doctor candidates | 2/2 since 10-13 | 3 | 2,916 in 26 files |
| 2. a removal leaves its other end: a retired feature's readers, flags, tests and prose, a deleted reader's writer, a unit the removal orphaned | 42 dead candidates, 5 code-ledger dead rows, 2 check refusals | 10 (10-03…10-13) | 5 ledger fixes (−252) + 9 relay commits | 572 dead code lines waiting |
| 3. every new tool rolls its own helpers (JSON IO, bounded runs) | 4 code-ledger rows | 5 (10-08…10-14) | 4 + 3 fit-round folds | 30 |

- Method of the table (2026-10-16, rerun 2026-10-20 to the same counts):
  - class 1: `git ls-files local-config/home` at a path a sweep repository deploys, `wc -l`: llm-legs `DEPLOYS` (21
    files, 2,818 lines), review-bench `share/rbench/debt.py` `doctor_agent_paths` (`review-doctord`,
    `com.llm-legs.review-doctor.plist`: 27), claude-setup end-report's `launchd/` pair (README `install`: 37),
    hammerspoon `launchd/com.egor.hammerspoon.plist` (34). `libexec/hammerspoon` (2), which that plist runs, has no
    source or installer in any repository: out, unconfirmed;
  - class 2: dead lines = `lines` of the units the 42 `dead` rows of `candidates.jsonl` name as dead in `detail`
    (`X is defined and never called`, `no entry point reaches X, Y`), each once, a unit in a test path out (683 with
    it; all 26 files still stand at HEAD 2026-10-20); the `is N lines with N branches` units (worker-run,
    instruction-files.sh: 11,534) and clone-only units (24) are out; `value` adds a clone signal: 695; days = the
    dead-row fixes, relay sweep, stamp and refusals; relay commits = `git log
    --first-parent -i -E --grep='^relay (leftovers|cleanup)|^relay-free polish|retired relay|dangling worker-relay'`
    from 10-09 on, less two Spend audits (fc86109c, 3e8062e0);
  - class 3: `def read_json(`, `def read_jsonl(`, `def write_json(`, `local-config/` out; lines = per repository,
    every body less the longest per name, less the copies the code ledger keeps on purpose (chat-load: deployed
    beside memlogd; harness-doctor's `read_jsonl`: a binary tail reader; review-anchors: a standalone script): at
    HEAD 2026-10-20 llm-legs `read_json` 6 (code-doctor, spend.py) + `write_json` 24 (five tools).

Why they come back:
1. The snapshot (d2ecaa0, 10-13) copies every file in `~/.local/libexec` and every agent plist naming it. Installers
   in all four repositories deploy there, because launchd cannot run a program off /Volumes/Work. Only llm-legs lists
   its copies (`DEPLOYS`, with installers, healing drift by `harness-doctor --redeploy`); the snapshot reads no list.
   - 3 of the 10 libexec copies have drifted. Fixes to them do not last: a fit round synced store-lock.sh (1eaff59),
     a legacy round deleted ipad-mic-refresh (091c455), test_report_frame_guard gained an exemption (2612a804).
   - The Code doctor's judge spent all 16 verdicts of 10-14 (247k tokens) on these copies.
2. A retirement spans repositories while each commit is one, and the Code fixer may not finish its own.
   - Relay: retired 10-09 (ee185fa8, 46879c6). Its leftovers took 9 commits in 3 repositories, all but one on 10-09.
   - Delegated stamp: its reader went in review-bench 6a684df. The writers went 10-08 (7d353f02, fa10c66), the
     prose and a test block 10-12 (8090aa7).
   - `code-doctor check` refuses a Code fixer's deletion that no judged problem names, even of a unit the same run
     orphaned: normalizeDir stayed dead (10f7f32, 10-07), and the statusline.sh and grokb `run_bounded` migrations,
     green (84de7cc5), were reverted (7c9a9cc9, 10-13).
   - The Code doctor finds leftovers nights later and fixes 1 cause a day (yield 424 lines for 6.0M tokens, under
     `LOW_YIELD_PER_KTOK`, so `queue_k` = `TOP_K_LOW_YIELD` = 1); its judge takes 8–16 candidates a night under a
     400k token cap, so the queue grew from 109 pending (10-03) to 531 waiting (10-14).
   - Audits of retired components (spawn:codex-worker, spawn:review-waiter 10-10; cd-guard ×4 10-13) are Spend's:
     `due()` reopens a cut whose tail is still in the 7-day window (spend.md class 1, goal audit-due).
3. A new tool starts standalone, and a deployed copy (chat-load) cannot import `share/`. Each fold fixes one helper.
   REUSE FIRST in worker-run's brief preamble has asked for reuse since 09-18; the class came back anyway.

Checked, not a class:
- Readers of retired experiments: none of the 5 tags removed since 09-20 has one left (grep outside docs/handoffs).
- Names a retirement left in code or tests at its own commit, 10-09…15: of 103 commits deleting a file or
  definition, 2 (worker-corpus's frame-guard exemption, 138b5a6c; `words_grant_target` in a planted test, b50e5bff).
  Other hits were common words, variables, keys, an 8-second cross-repository pair, and 234256e0, which swept in a
  staged deletion a minute before its retirement (6280c424): a scan of deleted names would list mostly false hits.

## Goals

The pilot night works these goals in order, one at a time. A goal that lands moves to Done with its commit and proof.
A goal that fails stays here with one line on what blocked it.

### goal deployed-copies: the machine snapshot leaves out what any sweep repository deploys

Class 1, one rule for the four repositories: each lists its deploys; the snapshot leaves out every listed path.
- First step (unconfirmed): who writes `~/.local/libexec/hammerspoon`, the wrapper hammerspoon's plist runs. No
  repository has its source or installer; hammerspoon lists it if it owns it, else it stays in the tree.
- Where: each repository prints its copies one way, home path and installer (`cp <source>` for a hand copy), from
  one list (no second list, no byte or name matching): llm-legs `harness-doctor --deploys` from `DEPLOYS`;
  review-bench from `doctor_agent_paths` (`review-bench doctor --install-agent`); claude-setup end-report's
  `launchd/` pair; hammerspoon its plist.
  - claude-setup `bin/night-snapshot` leaves out every path a list prints; `bin/restore-local`, once the
    repositories are cloned, runs each installer instead of copying, then starts the agents as now.
  - The 26 copies leave the tree, with test_report_frame_guard's local-config skip.
- Proof, on each night's snapshot commit for 7 days after landing: lines under `local-config/home` by class 1's
  method, plus any file there `cmp`-equal to a tracked file of the four (a deploy no list names): 2,916 in 26 files
  → 0, each repository at 0. Code doctor duplicate candidates with a `local-config/` file: 111 of 247 → 0, at a
  `code-doctor refresh` the measurer runs.
- Must not get worse: `restore-local` into a scratch `HOME`, `launchctl` stubbed on `PATH` (installers bootstrap the
  real `gui/$UID` whatever `HOME` says), restores today's file set under `.local/libexec` and `Library/LaunchAgents`;
  the live `~/.local/libexec` is only read.

### goal own-orphans: a Code fixer deletes what its own change orphaned

Class 2's Code fixer cause only (Decision 2026-10-09: change impact): the relay and stamp leftovers came from
retirements by chats and workers, which `check` never sees, and stay in the class.
- Where: llm-legs `bin/code-doctor` `check` (bin/code-doctor:3464–3476).
  - A deletion no judged problem names passes when every reference to the unit at the run's base sits in lines the
    same run deletes, its own definition aside, or the unit is a copy whose callers the run moved to a shared one.
  - Every other unjudged deletion stays refused.
- Proof, old → new on this machine: replay both refusals in scratch worktrees (10f7f32 plus normalizeDir's deletion;
  84de7cc5's statusline.sh and grokb migrations, which 7c9a9cc9 reverted): old `check` refuses both, new passes both,
  both refuse a live unit. No full-night count: Code fixer runs only there, 1 cause a day against 531 waiting.
- Must not get worse: no unit `check` passes keeps a `git grep -w` hit outside the run's deleted lines in the four
  trees; `doctor-fix close` time for a Code run.

## Done

- Retired features took their tests with them: llm-legs `test_light_edit`, `test_land`, `test_worktree`,
  `test_night_report_trial`; claude-setup 5 files. The tests lens rounds of 10-14 are lost-time.md's Done.

## Decisions

- 2026-10-20: everything about tests is one block, Tests and lost time; Legacy is code only, its "tests apart"
  metric code only. It replaces 10-15's "obsolete tests are Legacy's". («Updater doctor»)
- 2026-10-15: the harness's code and tests shrink, not grow. («Updater doctor»)
- 2026-10-14: unused code is deleted together with its tests, with no "Egor asked" marker; what he wants kept, he
  asks a test for. («Updater doctor»)
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

- Change impact beyond code and tests (2026-10-09): hooks, docs and actions a landed change made obsolete. No class
  or goal counts them.
