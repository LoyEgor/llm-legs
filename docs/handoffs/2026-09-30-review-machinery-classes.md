# Hand-off: the five review machinery classes, triaged

Status: done

For the chat «Review-bench improvements phase 4» (`share/doctor-ledger.json` `owners.reviewers`),
which owns review-bench `share/rbench/debt.py` `DOCTOR_CHECKS`. Opened 2026-09-30 by night fixer
run `llm-reviewers-20260930T001641Z-5fac`; re-triaged every night since (latest
`llm-reviewers-20261004T013819Z-21fd`), no machinery bug behind the counts. Nothing was dismissed;
each ledger row's `note` keeps the nightly numbers.

## Yours to decide

1. **M1 `anchors` (~790 nightly) and M5 `debt_line`.** Nearly all are `gap-stale` rows of ONE live
   chat, «Vector Magic macOS ARM migration», in `logo-vectorizer-bench`: that tree holds 65 098 dirty
   paths (untracked bench outputs under `results/`, `tracers/`, not in its `.gitignore`), so
   claude-setup `hooks/lib/review-journal.sh` writes a `hash-cap` gap on every Bash call (3 245
   lines in its gaps file by 2026-10-04), each with a different detail, so `doctor_check_row` keys
   each apart. `review-debt` for that chat outlasts `doctor_debt_line_rows`' 60 s timeout (M5
   `TimeoutExpired`); raising it would hide the cause. Any other chat that runs a Bash call in that
   tree gets a `hash-cap` gap too (WHY=gap). Proposals, each lowering a count: key `gap-stale` rows
   per (session, kind, checkout); write the hook's hash-cap gap once per (session, checkout);
   release an abandoned round's claims automatically. The tree's ignore list is that chat's work.
   Since review-bench fd9aa06/5ee444e such a row names its own path (`logo-vectorizer-bench`), not the
   family check that listed it (`claude-setup`).
2. **M5, `run-fold … not a repository`.** A worker run whose family worktree the chat removed
   mid-run is folded in that family's store since llm-legs a3ac7e8e, and still files the gap so the
   fold never reads as "nothing changed"; the chat's next review mark settles it.
3. **M3 `debt_scope` (~25).** `debt_round_suspect` flags a round when shared lines exceed half of
   it or any unanchored fix line exists. Every cleanup round over the four sweep repositories is
   ~100 % shared (e.g. 20261003T042759Z-499d5df, 13 240 lines), and a chat fixing a round itself
   leaves no `fix:R:*` anchor. Decide whether the class measures a defect or the normal shape of a
   shared checkout.
4. **M4 `integrity` (1-11).** Concurrent edits by other chats in the shared checkout (the record
   itself calls them an observation, actor `unknown`) and ignored files tools write on their own
   (claude-setup `skills/synced/*`, `.nx/workspace-data/d/daemon.log`, night worktrees under
   `.claude/worktrees/`). Proposal: leave ignored paths out of the class, or add them to
   `DOCTOR_INTEGRITY_NOISE_RE`. That narrows the class, so it is yours.
5. **R1 floor on edited docs.** A clean docs chunk was refused at 12 KB read against a 22.8 KB
   floor: `docs/shared-invariants.md` rows run to 17 KB, so 24 changed lines are 152 KB of diff.
   Pricing edited `.md` by changed lines would lower the floor, so it is yours.

## Settled 2026-10-04 (owner, branch `fix/reviewers-handoffs-20261004`)

1. **Fixed + test.** `doctor_check_row` keys a `gap-stale` row per (session, kind, checkout) when the
   gap names one, so one tree past the hash cap is one row, not one per Bash call
   (test_review_debt `test_doctor_prints_each_gap_once…`, red on the old code). `review-debt` prices
   only the path names its session touched (`priced_touches(session=)`): a family's linked worktrees
   holding none of them get no git (live: claude-setup 10.9 → 3.5 s, llm-legs 30.3 → 15.4 s per
   call; `test_a_session_line_asks_git_only_of_the_worktrees_holding_its_paths`, red twice by
   mutation). The Vector Magic chat's `TimeoutExpired` stays: 700 of its 790 s are its own 72 076
   touched paths in logo-vectorizer-bench (`moved_lines` 408 s, `working_blobs` 217 s), whose
   `results/`/`tracers/` ignore list is that chat's — handoff
   `2026-10-04-logo-vectorizer-bench-ignore-list.md`. M1 and M5 stay open on that cause alone.
2. **Closed.** llm-legs a3ac7e8e (in main) folds the run in each family (`fold_gone_checkout`); the
   gap is kept on purpose and settles at the session's next review mark.
3. **Fixed (deleted).** The doctor check `debt_scope` and the `SUSPECT` mark are gone: the rule
   flagged 55 of 59 journalled rounds (20 of 21 in 7 days), single-chat rounds of 22 lines included,
   so it told nothing apart. `debt-stats` keeps the shared and unanchored numbers for a reader
   chasing a misattributed charge.
4. **Fixed + test.** `doctor_integrity_rows` leaves out paths git ignores (`.git/info/exclude`
   included), red on the old code. Tracked-file edits by other chats stay: the class cannot tell
   them from a cell's write, which is what it is for.
5. **Fixed + test.** The read coverage floor prices each diff line at most
   `READ_COVERAGE_LINE_CAP = 200` bytes (`scope.coverage_bytes`, data dumps and chunks alike); a code
   diff prices as before. test_review_bench_panels: a 17 KB-row docs edit read for 12 KB stands.
