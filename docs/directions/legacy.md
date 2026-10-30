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
3 30 (HEAD).

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
    b2d851be 21a08465, hammerspoon 01153ba2 5d953cf3 f1872c3a.

## Sources

- Code doctor (`~/.cache/code-doctor/`, last refresh 2026-10-30 09:10): `latest.json` (counts by group, yield),
  `candidates.jsonl` (495 candidates with files and units), `verdicts.json`, `judge-runs.jsonl`, `accounting.jsonl`.
  Pilot nights run no refresh, judge or Code fixer (`bin/night-run` PILOT_RULES). A scratch refresh
  (`CODE_DOCTOR_DIR` = a copy) reads today's trees, the store untouched (32 s).
- `share/code-ledger.json`: the Code doctor's 9 dead and duplicate rows, all fixed-pending, −424 lines 10-03…10-13.
- Each repository's `bin/deploys`: every copy it deploys and its installer.
- `share/harness-ledger.json`: no legacy rule; none of its log-audit rows is about dead or duplicate code.

## Recurring classes

Ranked 2026-10-16 by lines, from the ledgers, the Code doctor's candidates and git from 10-02 to 10-15; lines now
recomputed 2026-10-30, code only. Each class was fixed as an instance and came back.

| class | rows | days seen | instances fixed | lines now |
|---|---:|---:|---:|---:|
| 1. deployed copies: `night-snapshot` commits what a sweep repository deploys into claude-setup `local-config/home` | 111 Code doctor candidates | 2/2 since 10-13 | 3 | 0 |
| 2. a removal leaves its other end: a retired feature's readers, flags, tests and prose, a deleted reader's writer, a unit the removal orphaned | 42 dead candidates, 5 code-ledger dead rows, 2 check refusals | 10 (10-03…10-13) | 5 ledger fixes (−252) + 7 relay commits | 658 |
| 3. every new tool rolls its own helpers (JSON IO, bounded runs) | 4 code-ledger rows | 5 (10-08…10-14) | 4 + 3 fit-round folds | 58 |

- Method of the table (2026-10-16, rerun 2026-10-20 to the same counts, 2026-10-30 at the four HEADs):
  - class 1: `git ls-files local-config/home` at a path some repository's `bin/deploys` prints, `wc -l`;
  - class 2: dead lines = `lines` of the units the `dead` rows of `candidates.jsonl` name as dead in `detail`
    (`X is defined and never called`, `no entry point reaches X, Y`), each once, a unit in a test path out:
    `jq -r 'select(.group=="dead") | ([.detail|scan("([^ ;]+) is defined and never called")[0]] +
    ([.detail|scan("no entry point reaches ([^;]+)")[0]|split(", ")[]])) as $n | .units[] |
    select(.unit as $u|$n|index($u)) | select(.file|test("(^|/)(tests?/|test_)")|not) | "\(.unit)\t\(.lines)"'
    candidates.jsonl | sort -u`, summed
    (10-30: 51 units, 658; 769 with tests); `is N lines with N branches` and clone-only units are out;
  - class 3: `def read_json(`, `def read_jsonl(`, `def write_json(`, `local-config/` out; per repository, every
    body less the longest per name, less the code ledger's kept copies (chat-load, harness-doctor's `read_jsonl`,
    review-anchors): llm-legs `read_json` 18 + `write_json` 36 + `read_jsonl` 4 at HEAD 2026-10-30.

Why they come back:
1. The snapshot (d2ecaa0, 10-13) copied every deployed file and read no list. Settled by goal deployed-copies.
2. A retirement spans repositories while each commit is one, and the Code fixer may not finish its own.
   - Relay (retired 10-09) took 7 leftover commits in 3 repositories; the delegated stamp's reader, writers and
     prose went in 4 commits 10-08…12.
   - The Code doctor finds leftovers, then never reaches them (10-30): `run_judge` and `night_snapshot` rank by
     `value` across groups, so the 49 dead rows wait from rank 131 (median 344) of 464 pending; 10-29's 3 judge runs
     gave 47 verdicts, 2 dead. A `problem` verdict goes stale on any edit of its evidence and re-queues (6 dead ones
     from 10-03…05, e.g. `log_upkeep.lua`). Fixer 1 cause a night: yield 489 lines for 7.03M tokens.
   - Audits of retired components are Spend's (spend.md class 1, goal audit-due).
3. A new tool is modeled on a sibling and copies its helpers (goal lift-not-copy); a deployed copy cannot import
   `share/`. The method's three names miss the rest of the class.

Checked, not a class:
- Change impact beyond code (Open 10-09, measured 10-30): of 82 backticked repo paths in `*.md` resolving nowhere,
  71 sit in handoffs and the 11 in docs and instructions are all false (another repository, state dirs, history,
  fixtures); no hook or LaunchAgent names a missing file; the `promise` group's 43 verdicts found no obsolete prose.
  Measurable, not a class.
- Readers of retired experiments: none of the 5 tags removed since 09-20 has one left (grep outside docs/handoffs).
- Names a retirement left at its own commit, 10-09…15: 2 of 103 deleting commits (138b5a6c, b50e5bff); a scan of
  deleted names lists mostly false hits.
- Deep search 10-23, dropped: unused tools (every sweep `bin` tool and the 13 largest tools' flags ran in 35 d; every
  jq `def` referenced); gates (5 rare-event gates, 232 lines, denied nothing in 35 d: silence is not need); exact
  clones (143 lines, 54 the 9-line `resolve_root`); superseded machinery (claudebd, xAI-direct, relay left no code).

Nothing to gain (10-30): class 1, 0 lines; class 3, 58, all born before 647bf70c (lift-not-copy's read covers it).

## Goals

## Held goals

Wait for the 11-05 read.

### goal dead-first: the Code doctor reaches its dead rows

- Class 2: 658 lines, 51 units (method above): name-dispatch false hits 195 (`bin/page` `cmd_*` 113 via
  `globals()["cmd_" + …]`, `vendor-fingerprint` `*_facets` 82 via `"${vendor}_facets"`), not-now 224, stale
  `problem` 66, unjudged 173. Their tests are cases in suites that stay: no wait lever. Spend: 19–44k judge tokens
  a row.
- First step: replay `run_judge`'s order on a `CODE_DOCTOR_DIR` copy; stop if dead rows already lead the pending.
- Fix: dead rows first in `run_judge` and `night_snapshot` (removal is cheapest to judge and fix, so yield and
  `queue_k` rise); the graph reads `globals()[prefix + …]` and `"${var}_suffix"` dispatch.
- Proof on the copy, old → new: dead rows in the first 16 pending 0 → 16, false-hit rows 10 → 0; 7 days after
  landing class 2 ≤ 330 lines, `queue_k` > 1.
- Files: llm-legs `bin/code-doctor`, `tests/test_code_doctor.sh`.
- Checked 10-30 (fresh run): every number reproduces. The cross-repository retirement upstream stays, since
  removal is asked in prose, never by a mechanism (Decision 2026-09-30). Stale `problem` re-queues are outside this goal.

## Done

- goal lift-not-copy (llm-legs 647bf70c; claude-setup global/CLAUDE.md `## Reuse`): REUSE FIRST and chats' CLAUDE.md say
  "use it by import … never a copy". First step held: 4 of the 5 largest writers read the copied helper's body
  first. Preamble +119 bytes; CLAUDE.md 5,182 → 5,381. Forward read 7 days after landing: 10.7 → ≤ 5.4
  re-rolled helper lines per 1k code lines added, near-copies and same-call re-rolls apart.
- goal own-orphans (08914fb6): `check` passes an unjudged deletion whose base references all sat in the run's judged
  deleted units, or a copy moved onto the judged merge's shared file. Replays: 2 refused → passed, a live unit
  refused in both; check +0.1–0.3 s.
- goal deployed-copies (llm-legs 30eaae1a, claude-setup e6b97de, review-bench 546967d, hammerspoon 0da6d28): each
  repository's `bin/deploys` prints its copies and installers, hammerspoon's wrapper included (its source now
  `launchd/`); `night-snapshot` leaves them out, `restore-local` runs the installers. Class 1: tree 2,916 lines in 26
  files → 0, fresh 10-23 snapshot 3,085 → 0, `cmp`-equal 13 → 0; scratch restore keeps its 28 + 19 files. 7-day
  read 10-30 held: 0 lines, 0 files at every HEAD (30 deployed paths, 20 `local-config/home` files, none shared),
  Code doctor candidates 111 → 0.
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
