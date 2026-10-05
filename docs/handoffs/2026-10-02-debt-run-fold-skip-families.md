# run-fold-skip losses come from family folds of long runs

Status: done 2026-10-05 — superseded: review-bench@c23eb96 (repo-level debt) removed the loss writer

Ledger H13. Option 1 (2026-10-04, review-bench@1a76edc) kept a commit no hook saw as a loss, so
committed-since family folds went on logging. c23eb96 prices debt from git: run-fold without a round
writes nothing, and `append_loss` is gone. The owner «Debt hardening handoff» deletes the row in its
stage 2 (review-bench `docs/handoffs/2026-10-05-repo-level-debt.md`).
