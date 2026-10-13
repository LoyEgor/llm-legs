# Statusline debt `⟟N`: moved-key floor 15 s → 60 s

Status: open
To: Egor. From: night fixer harness-speed-cpu-statusline-render (20261012T233034Z-3131).

`cpu:statusline/debt` is 77 CPU-min/day (1460 runs, 2.6 s each, `review-debt --repo`, review-bench). Its answer was
unchanged in 278 of 855 runs one day; run gaps: ≤20 s 796, 20-60 s 511, 60-300 s 446. A moved key is asked again once the
answer is 15 s old (`repo_debt_lines`, `bin/statusline.sh`), so edits keep it recomputing.

Cost: one constant in `bin/statusline.sh` plus the contract row (2 lines).
Loss: `⟟N` lags up to 60 s after an edit or an anchor write instead of 15 s.
Saving: up to ~45 % of the row (~35 CPU-min/day), estimated from the gap histogram, not replayed.
Recommendation: do it.
Other lever: pricing the whole family in `review-bench` (`rbench.debt`) is that repo's owner's; `price_family` is
memoized already (review-bench@be0b79d), so what is left is the walk over 82 worktrees on a moved key.
