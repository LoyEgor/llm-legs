# Hand-off: the five review machinery classes, triaged

Status: done

For the chat «Review-bench improvements phase 4» (`share/doctor-ledger.json` `owners.reviewers`),
which owns review-bench `share/rbench/debt.py` `DOCTOR_CHECKS`. Opened 2026-09-30 by night fixer
run `llm-reviewers-20260930T001641Z-5fac`; re-triaged every night since (latest
`llm-reviewers-20261004T013819Z-21fd`), no machinery bug behind the counts. Nothing was dismissed;
each ledger row's `note` keeps the nightly numbers.

## Settled 2026-10-04 (owner, branch `fix/reviewers-handoffs-20261004`)

1. **M1/M5: fixed + test.** `doctor_check_row` keys a `gap-stale` row per (session, kind, checkout) when the
   gap names one, so one tree past the hash cap is one row, not one per Bash call
   (test_review_debt `test_doctor_prints_each_gap_once…`, red on the old code). `review-debt` prices
   only the path names its session touched (`priced_touches(session=)`): a family's linked worktrees
   holding none of them get no git (live: claude-setup 10.9 → 3.5 s, llm-legs 30.3 → 15.4 s per
   call; `test_a_session_line_asks_git_only_of_the_worktrees_holding_its_paths`, red twice by
   mutation). The Vector Magic chat's `TimeoutExpired` stays: 700 of its 790 s are its own 72 076
   touched paths in logo-vectorizer-bench (`moved_lines` 408 s, `working_blobs` 217 s), whose
   `results/`/`tracers/` ignore list is that chat's — handoff
   `2026-10-04-logo-vectorizer-bench-ignore-list.md`. M1 and M5 stay open on that cause alone.
2. **M5 `run-fold`: closed.** llm-legs a3ac7e8e (in main) folds the run in each family (`fold_gone_checkout`); the
   gap is kept on purpose and settles at the session's next review mark.
3. **M3 `debt_scope`: deleted.** The doctor check `debt_scope` and the `SUSPECT` mark are gone: the rule
   flagged 55 of 59 journalled rounds (20 of 21 in 7 days), single-chat rounds of 22 lines included,
   so it told nothing apart. `debt-stats` keeps the shared and unanchored numbers for a reader
   chasing a misattributed charge.
4. **M4: fixed + test.** `doctor_integrity_rows` leaves out paths git ignores (`.git/info/exclude`
   included), red on the old code. Tracked-file edits by other chats stay: the class cannot tell
   them from a cell's write, which is what it is for.
5. **R1: fixed + test.** The read coverage floor prices each diff line at most
   `READ_COVERAGE_LINE_CAP = 200` bytes (`scope.coverage_bytes`, data dumps and chunks alike); a code
   diff prices as before. test_review_bench_panels: a 17 KB-row docs edit read for 12 KB stands.
