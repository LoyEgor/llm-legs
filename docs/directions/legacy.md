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

- Code doctor (`~/.cache/code-doctor/`, last refresh 2026-10-14 12:19): `latest.json` (counts by group, yield),
  `candidates.jsonl` (549 candidates with files and units), `verdicts.json`, `judge-runs.jsonl`, `accounting.jsonl`.
  Pilot nights run no refresh, judge or Code fixer (`bin/night-run` PILOT_RULES). A scratch refresh
  (`CODE_DOCTOR_DIR` = a copy of it) reads today's trees and leaves it untouched: 32 s at 10-23 21:44.
- `share/code-ledger.json`: the Code doctor's 9 dead and duplicate rows, all fixed-pending, −424 lines 10-03…10-13.
- llm-legs `bin/harness-doctor` `DEPLOYS`: every copy llm-legs installers deploy, its source, kind and installer.
- `share/harness-ledger.json`: no legacy rule. None of its 105 log-audit rows is about dead or duplicate code.

## Recurring classes

Ranked 2026-10-16 by lines, from the ledgers, the Code doctor's candidates and git from 10-02 to 10-15; lines now
recomputed 2026-10-20, code only. Each class was fixed as an instance and came back.

| class | rows | days seen | instances fixed | lines now |
|---|---:|---:|---:|---:|
| 1. deployed copies: `night-snapshot` commits what a sweep repository deploys into claude-setup `local-config/home` | 111 Code doctor candidates | 2/2 since 10-13 | 3 | 2,916 in 26 files |
| 2. a removal leaves its other end: a retired feature's readers, flags, tests and prose, a deleted reader's writer, a unit the removal orphaned | 42 dead candidates, 5 code-ledger dead rows, 2 check refusals | 10 (10-03…10-13) | 5 ledger fixes (−252) + 7 relay commits | 572 dead code lines waiting |
| 3. every new tool rolls its own helpers (JSON IO, bounded runs) | 4 code-ledger rows | 5 (10-08…10-14) | 4 + 3 fit-round folds | 30 |

- Method of the table (2026-10-16, rerun 2026-10-20 to the same counts):
  - class 1: `git ls-files local-config/home` at a path a sweep repository deploys, `wc -l`: llm-legs `DEPLOYS` (21
    files, 2,818 lines), review-bench `share/rbench/debt.py` `doctor_agent_paths` (`review-doctord`,
    `com.llm-legs.review-doctor.plist`: 27), claude-setup end-report's `launchd/` pair (README `install`: 37),
    hammerspoon `launchd/com.egor.hammerspoon.plist` (34); its wrapper `libexec/hammerspoon` is out;
  - class 2: dead lines = `lines` of the units the 42 `dead` rows of `candidates.jsonl` name as dead in `detail`
    (`X is defined and never called`, `no entry point reaches X, Y`), each once, a unit in a test path out (683 with
    it); the `is N lines with N branches` units (worker-run,
    instruction-files.sh: 11,534) and clone-only units (24) are out; `value` adds a clone signal: 695; days = the
    dead-row fixes, relay sweep, stamp and refusals; relay commits = `git log --first-parent -i -E
    --grep='^relay (leftovers|cleanup)|^relay-free polish|retired relay|dangling worker-relay'` on the four
    repositories, committer `%cI` local ≥ 2026-10-09 (not `--since`, UTC), less fc86109c and 3e8062e0: 7;
  - class 3: `def read_json(`, `def read_jsonl(`, `def write_json(`, `local-config/` out; lines = per repository,
    every body less the longest per name, less the copies the code ledger keeps on purpose (chat-load: deployed
    beside memlogd; harness-doctor's `read_jsonl`: a binary tail reader; review-anchors: a standalone script): at
    HEAD 2026-10-20 llm-legs `read_json` 6 (code-doctor, spend.py) + `write_json` 24 (five tools).

Why they come back:
1. The snapshot (d2ecaa0, 10-13) copied every deployed file and read no list; the judge spent all 16 verdicts of
   10-14 (247k tokens) on these copies. Settled by goal deployed-copies.
2. A retirement spans repositories while each commit is one, and the Code fixer may not finish its own.
   - Relay: retired 10-09 (ee185fa8, 46879c6). Its leftovers took 7 commits in 3 repositories, all but one on 10-09.
   - Delegated stamp: its reader went in review-bench 6a684df. The writers went 10-08 (7d353f02, fa10c66), the
     prose and a test block 10-12 (8090aa7).
   - The Code doctor finds leftovers nights later and fixes 1 cause a day (yield 424 lines for 6.0M tokens, under
     `LOW_YIELD_PER_KTOK`, so `queue_k` = `TOP_K_LOW_YIELD` = 1); its judge takes 8–16 candidates a night under a
     400k token cap, so the queue grew from 109 pending (10-03) to 531 waiting (10-14).
   - Audits of retired components (spawn:codex-worker, spawn:review-waiter 10-10; cd-guard ×4 10-13) are Spend's:
     `due()` reopens a cut whose tail is still in the 7-day window (spend.md class 1, goal audit-due).
3. A new tool is modeled on a sibling and copies its helpers (goal lift-not-copy); a deployed copy (chat-load)
   cannot import `share/`. Each fold fixes one helper. The method's three names miss the rest of the class.

Checked, not a class:
- Readers of retired experiments: none of the 5 tags removed since 09-20 has one left (grep outside docs/handoffs).
- Names a retirement left in code or tests at its own commit, 10-09…15: of 103 commits deleting a file or
  definition, 2 (worker-corpus's frame-guard exemption, 138b5a6c; `words_grant_target` in a planted test, b50e5bff).
  Other hits were common words, variables and keys: a scan of deleted names would list mostly false hits.
- Deep search 10-23, dropped:
  - class 2 inflow since 10-14 (scratch refresh): +4 units, 25 lines (one a `do_POST` dispatch false hit), −2
    units, 16: 572 → 585;
  - unused tools: every sweep `bin` tool ran in 35 d (model Bash calls deduped by tool_use id, or a code caller),
    and the 13 largest tools' flags too, bar a few argparse lines; unparsed jq (729 lines): every `def` referenced;
  - gates: retired hooks' files are all gone; 5 registered gates (232 lines) denied nothing in 35 d, each a
    rare-event guard (Jira, MCP scope, skill names, end of day): silence is not need;
  - exact clones at HEAD: 143 lines, 54 of them the 9-line bin `resolve_root` that finds `share/` before importing;
  - superseded machinery: no journal names it; claudebd, xAI-direct and relay names left no code; no experiment
    overdue.

## Goals

## Done

- goal lift-not-copy (llm-legs 647bf70c; claude-setup global/CLAUDE.md `## Reuse`): REUSE FIRST and chats' CLAUDE.md say
  "use it by import … never a copy". First step held: 4 of the 5 largest writers (suno_music, cpu_audit#tally,
  awdl_guard#startDemandWatch, system-doctor#worker_judge) read the copied helper's body first; words_journal's
  transcript is gone. Preamble +119 bytes; CLAUDE.md 5,182 → 5,381. Forward read 7 days after landing: 10.7 → ≤ 5.4
  re-rolled helper lines per 1k code lines added, near-copies and same-call re-rolls apart.
- goal own-orphans (08914fb6): `check` passes an unjudged deletion whose base references all sat in the run's judged
  deleted units and stay gone, or a copy moved onto the judged merge's shared file. Replays old → new: 10f7f32 +
  normalizeDir, 84de7cc5's statusline.sh/grokb copies refused → passed; a live unit refused in both; check +0.1–0.3 s.
- goal deployed-copies (llm-legs 30eaae1a, claude-setup e6b97de, review-bench 546967d, hammerspoon 0da6d28): each
  repository's `bin/deploys` prints its copies and installers, hammerspoon's wrapper included (its source now
  `launchd/`); `night-snapshot` leaves them out, `restore-local` runs the installers. Class 1: tree 2,916 lines in 26
  files → 0, fresh 10-23 snapshot 3,085 → 0, `cmp`-equal 13 → 0; scratch restore keeps its 28 + 19 files. 7-day
  read 10-30 (+ Code doctor candidates 111 → 0).
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

- Change impact beyond code and tests (2026-10-09): docs and actions a landed change made obsolete (hooks checked
  10-23, above). No class or goal counts them.
