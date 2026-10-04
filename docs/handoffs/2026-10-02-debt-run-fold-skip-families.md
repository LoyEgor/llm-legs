# run-fold-skip losses come from family folds of long runs

Status: done 2026-10-04 (option 1; ledger H13 fixed-pending)

For the ledger owner «LLM Doctor меню refactoring», routing the loss semantics to Review-bench
improvements phase 4 (`review-bench/bin/review-anchors` `cmd_run_fold`). Run:
llm-debt-20261002T093021Z-7720; ledger row H13; blind spot B5 stays the detector-side record.

## Evidence (24 h window ending 2026-10-02 09:30 UTC)

- 35 runs, 141 path rows "a co-tenant touched it during the run" and 283 "committed since the run
  started" in `~/.cache/claude/review-debt/losses.jsonl`.
- 34 of the 47 (run, repository) pairs are folds of a FAMILY, not of the run's workdir: the
  repositories in the launching chat's `.repos` list, snapshotted under `<run-dir>/families/<n>/`
  by `bin/worker-run` `snapshot_other_families`.
- Example: `claudeb-1790842639-39826-35a2`, workdir `/Volumes/Work/Projects/video/alona/R7-B` (no
  git), ran 4.5 h. Its family folds of the llm-legs and claude-setup main checkouts took every path
  other chats changed or committed in that window (69 llm-legs rows alone).

## Mechanism

`fold_run_anchors` calls `fold_family_anchors` for each family with no `only` paths when the run has
no review round, so the family's whole before/after diff goes to `review-anchors run-fold`. There,
`cmd_run_fold` puts each foreign or committed path in `skipped` and appends a `run-fold-skip` loss
for it. Skipping takes away no owner: a co-tenant keeps its touch, and a commit is priced by commit
review. Most of these rows record that the run did NOT take a path. They are not debt that was lost.

## Options (owner decides; the judge is not loosened here)

1. review-anchors appends a loss only where no other session's touch or anchor holds the skipped
   path (B5 `would_catch_if`). This keeps every real drop and removes the false ones. Recommended.
2. worker-run narrows a family fold to the run's own named paths (`files-external` under that top).
   The noise goes, but a family write that no transcript or shell-writes row names is no longer
   charged to the launcher.

No ledger dismissal and no match narrowing beyond the kind were added.

## Settled 2026-10-04 («LLM Doctor меню refactoring», ledger owner)

Option 1 on branch `fix/llm-doctor-handoffs-20261004`: review-bench `bin/review-anchors` `cmd_run_fold` appends a `run-fold-skip` loss only
where nothing else holds the skipped path: no session's touch under this checkout and no non-`base` anchor
of its current content. A co-tenant's touch and a hook-seen commit (its touch, or its anchored blob) hold
it; a commit no hook saw (pull, `am`, plain git) stays a loss. `tests/test_review_debt.sh`: on main it logs
paths a, b, c, d, now only b; dropping the touch check or the anchor check turns it red. PASS 90;
`test_review_anchors` 117, `test_review_bench_rounds` 331. Left: a touch under a removed worktree's key
holds nothing, which can add a false loss, never hide a real one.
