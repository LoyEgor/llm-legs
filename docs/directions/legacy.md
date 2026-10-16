# Legacy (direction 5)

Code and tests nothing needs: dead code, duplicates, and obsolete or duplicate test checks.

## Metric

Net lines in the four sweep repositories (llm-legs, claude-setup, review-bench, hammerspoon), with code and tests
counted apart, 7 days against the 7 before. A test check leaves only when it is:
- stale: it guards a case the code can no longer produce;
- or covered: another suite's check fails on the same mutation.

### Baseline (computed 2026-10-16)

Git covers both windows whole, so each one is 7 full days.

| net lines, four repositories | 10-02…08 | 10-09…15 |
|---|---:|---:|
| **code** | **+27,340** (+38,415 −11,075) | **+16,153** (+26,728 −10,575) |
| **tests** | **+22,102** (+48,658 −26,556) | **+12,675** (+24,864 −12,189) |
| data: ledgers, `limits.json`, plists (own line) | +6,200 | +15,229 |
| docs, `*.md` (own line) | +478 | +376 |

- Code / tests per repository, 10-02…08 → 10-09…15: llm-legs +27,124 / +21,074 → +10,138 / +10,064; claude-setup
  +79 / +198 → +4,895 / +814; review-bench −425 / +387 → +742 / +786; hammerspoon +562 / +443 → +378 / +1,011.
- claude-setup's +4,895 code includes the 10-13 machine snapshot: +2,653 lines in `local-config/home/.local/libexec`
  alone (class 1 below; `git diff --numstat 2f02e870 dcd60c0f -- local-config/home/.local/libexec`).
- The data line is mostly llm-legs `share/spend-ledger.json` (+6,372) and `share/harness-ledger.json` (+5,869).
- Method:
  - A window's ends are each repository's commit `git rev-list -1 --first-parent --before='<day> 00:00' HEAD` for
    10-02, 10-09 and 10-16, local time. Lines are `git diff --numstat` between two ends, binary files skipped.
  - Buckets by path: tests = under a `tests/` or `test/` dir, or a `test_*` file; docs = `*.md`; data =
    `*.json|jsonl|plist|txt|log|csv|yaml`; code = the rest.
  - The ends: llm-legs 5e6a2951 af820ec9 916f78d6, claude-setup 64135192 2f02e870 dcd60c0f, review-bench bfe77bbb
    9dda0c3e 69c02d3d, hammerspoon fb9aa82b 31c703ac 0eabdd90.
- Not computable: covered checks. Each one needs a mutation run, and no journal records one. Stale checks show only
  as tests-lens findings, and the night's tests round has not run yet.

## Sources

- Lines: git in the four repositories, as in Method.
- Code doctor (`~/.cache/code-doctor/`, last refresh 2026-10-14 12:19): `latest.json` (counts by group, yield),
  `candidates.jsonl` (549 candidates with files and units), `verdicts.json`, `judge-runs.jsonl`, `accounting.jsonl`.
- `share/code-ledger.json`: the Code doctor's dead and duplicate rows. 9 rows, all fixed-pending, 424 lines
  removed between 10-03 and 10-13.
- `share/spend-ledger.json`: the audit rows of retired components (class 2).
- `share/harness-ledger.json`: no legacy rule. None of its 105 log-audit rows is about dead or duplicate code.
- Duplicate scans of the tracked trees, 2026-10-16: identical helper bodies and 6-line blocks (methods below).

## Recurring classes

Ranked 2026-10-16 by lines, from the ledgers, the Code doctor's candidates and git from 10-02 to 10-15. Each class
was fixed as an instance and came back.

| class | rows | days seen | instances fixed | lines now |
|---|---:|---:|---:|---:|
| 1. deployed copies: `night-snapshot` commits copies of sweep-repository files into claude-setup `local-config/home` | 111 Code doctor candidates | 2/2 since 10-13 | 3 | 2,747 in 15 files |
| 2. a removal leaves its other end: a retired feature's readers, flags, tests, prose and audit rows, or a deleted reader's writer, stay in the sibling repositories | 42 dead candidates, 5 code-ledger rows, 6 spend audits | 7 (10-03…10-13) | 5 ledger fixes (−252) + 11 relay commits | 695 dead lines waiting |
| 3. every new tool rolls its own helpers (JSON IO, bounded runs): definitions today, `read_json` ×3, `read_jsonl` ×4, `write_json` ×8 | 4 code-ledger rows | 5 (10-08…10-14) | 4 + 3 fit-round folds | 87 |
| 4. each suite redefines its assert helpers: `fail` copied identically 48 times, `assert` 40, `assert_fails` 8 | — | — | 1 fit round (10-14) | 451 |

- Method of the table, at HEAD on 2026-10-16:
  - class 1: `git ls-files local-config/home` under `.local/libexec` and `Library/LaunchAgents`, byte-equal (`cmp`)
    to a tracked llm-legs or hammerspoon file or among `memlogd install_agent`'s sources; lines by `wc -l`;
  - class 2: dead lines = the sum of `value` over the 42 `dead` rows of `candidates.jsonl`; days = the dates of the
    code ledger's 5 dead-row fixes and the 6 spend audits; relay commits = `git log --first-parent -i -E
    --grep='^relay (leftovers|cleanup)|^relay-free polish|retired relay|dangling worker-relay'` from 10-09 on;
  - class 3: `def read_json(`, `def read_jsonl(`, `def write_json(` in the four trees, `local-config/` copies left
    out; lines = every definition's body less the longest one per name;
  - class 4: `fail()`, `assert()`, `assert_fails()` bodies in tracked `*.sh`, counted by identical text; lines =
    every copy of a body seen twice or more, less one per body;
  - shared 6-line blocks: windows of 6 non-blank lines, whitespace-stripped, found in two or more tracked test
    files (the Method's tests bucket, text files at HEAD, 163,052 lines); a pair's number is one side's lines.

Why they come back:
1. The snapshot (d2ecaa0, 10-13) copies every file in `~/.local/libexec`. `memlogd install-agent` deploys
   llm-legs files there, because launchd cannot run a program off /Volumes/Work.
   - 3 of the 10 libexec copies have drifted. Fixes to them do not last: a fit round synced store-lock.sh (1eaff59),
     a legacy round deleted ipad-mic-refresh (091c455), test_report_frame_guard gained an exemption (2612a804).
   - The Code doctor's judge spent all 16 verdicts of 10-14 (247k tokens) on these copies.
2. A retirement lands in one repository and leaves its other ends for later rounds.
   - Relay: retired 10-09 (ee185fa8, 46879c6). Its leftovers took 11 commits in 3 repositories through 10-12.
   - Delegated stamp: its reader went in review-bench 6a684df. The writers went 10-08 (7d353f02, fa10c66), the
     prose and a test block 10-12 (8090aa7).
   - Audits ran on retired components: spawn:codex-worker and spawn:review-waiter on 10-10, and cd-guard 4 times on
     10-13, after it was retired on 10-12 (55f0a21).
   - The Code doctor finds leftovers only after the fact, nights later. It fixes 1 cause a day: its yield, 424 lines
     for 6.0M tokens, is under `LOW_YIELD_PER_KTOK`, so `queue_k` drops to `TOP_K_LOW_YIELD` = 1. Its judge takes
     8–16 candidates a night under a 400k token cap, so the queue grew from 109 pending (10-03) to 531 waiting
     (10-14).
3. A new tool starts standalone, and a deployed copy (chat-load) cannot import `share/`. Each fold fixes one helper.
4. A new suite copies its preamble. Splits are not the cause: 6 splits since 10-03 netted +18…+73 each over a shared
   harness.

Checked, not a class:
- Copied fixtures across split suites: shared 6-line blocks total 1,822 lines, 1.1 % of test lines; the largest
  pair is test_codexb/test_geminib with 92.
- Readers of retired experiments: the 5 tags removed from EXPERIMENTS.json since 09-20 have no reader left (grep
  outside docs/handoffs).
- The rest of the test growth is new suites for new code: test_test_health, test_tool_mining, test_log_stores…

## Goals

The pilot night works these goals in order, one at a time. A goal that lands moves to Done with its commit and proof.
A goal that fails stays here with one line on what blocked it.

### goal deployed-copies: the machine snapshot names what a sweep repository deploys instead of copying it

Class 1.
- Where: claude-setup `bin/night-snapshot` and `bin/restore-local`.
  - A file under `~/.local/libexec` or `~/Library/LaunchAgents` that a sweep repository deploys becomes one
    `deployed.tsv` line, home path → repository path, beside `links.tsv`.
  - Deployed means byte-equal to a tracked llm-legs or hammerspoon file, or named in a deployer's list (`memlogd
    install_agent`'s sources, which also covers the drifted chat-load, chat_names.py and limit-hit.sh). Never by
    name alone: the exec shims (`system-doctor`, `vendor-cli-update`) stay copied, and libexec `harness-doctor` maps
    to `launchd/harness-doctor`, not `bin/harness-doctor`.
  - `restore-local` puts each one back from its repository, then starts its agent as it does now.
  - The 15 copies leave the tree, and the exemptions made for them go too (test_report_frame_guard's local-config
    skip).
- Proof, old → new on this machine:
  - Lines under claude-setup `local-config/home` that copy a sweep-repository file: 2,747 → 0: 10 libexec files
    (2,601 lines; the 7 byte-equal plus the 3 drifted) and 5 byte-equal plists (146), by `git ls-files` + `cmp`.
  - Code doctor duplicate candidates with a `local-config/` file: 111 of 247 → 0 at the next `code-doctor refresh`,
    counted in `candidates.jsonl`.
- Must not get worse:
  - `restore-local` into a scratch `HOME` restores the same file set under `.local/libexec` and
    `Library/LaunchAgents` as today's snapshot, each deployed file equal to its repository source;
  - the live `~/.local/libexec` is only read.

### goal retire-whole: a change that retires something removes its other ends in the same change

Class 2: the leftovers are never written, rather than swept nights later.
- Where: llm-legs `bin/code-doctor` and the shared runner `share/run-suites.sh` behind every repository's
  `tests/run-all`. No new hook.
  - `code-doctor` scans the working change: the files and definitions its diff deletes or edits, against the `dead`
    group's existing detector over all four indexes.
  - `tests/run-all` runs that scan when the change deletes, and shows each dead candidate it finds as a red row with
    its `file#unit`, like a failing suite.
  - The judge, the fixer's snapshot, `queue_k` and the 400k token cap stay. The 42 waiting drain at the doctor's
    own pace.
- Proof, old → new: new dead candidates per retiring change, 7 days.
  - A retiring change: a first-parent commit in the four repositories that deletes a tracked file of the code or
    tests bucket (`git log --first-parent --diff-filter=D --name-only`); 15 in 10-09…10-15.
  - Its new dead candidates: the `dead` rows of `candidates.jsonl` at the first `code-doctor refresh` after it whose
    `detail` or `callers` name a file or definition the change deleted or edited.
  - Old: the refresh at the start of the night that works this goal, over 10-09…10-15. New: the refresh 7 days after
    landing, over that week. Target 0.
- Must not get worse:
  - no red row on a name still used (each one checked by `git grep`);
  - `tests/run-all` wall time on a change that deletes nothing: unchanged, since the scan does not run;
  - `candidates.waiting_by_group.dead` in `latest.json` stays at 42 or less;
  - Code doctor tokens a night (judge + critical in `accounting.jsonl` summed by `night`: 237k–887k on
    10-02…10-14).

## Done

- Retired features took their tests with them: llm-legs `test_light_edit`, `test_land`, `test_worktree`,
  `test_night_report_trial`; claude-setup 5 files.
- 10-14: a tests lens pilot on the 10 heaviest suites ran two rounds (05a7238f, 62458120): 131 fixes, +1,096 −803 =
  +293 lines. The lens as it stands strengthens weak checks, which adds lines, so cleanup here is deletion only.
- 10-14: the lens was tuned (review-bench 53f8137, 051aa8f), and a tests round joined the night's debt pass
  (9e852e4d), not yet run.

## Decisions

- 10-14: unused code is deleted together with its tests, with no "Egor asked" marker.
- 10-14: a stale check is deleted, never strengthened.
- 10-14: a suite that caught no defect in 90 days is deleted whole (`uncaught:` in doctor-fix's suite audit).
- The sweep repositories land everything in main; nothing is kept back on a list.

## Open

- Covered checks have no number until a mutation run records them. The tests round is the first source.
