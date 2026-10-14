# Statusline debt `⟟N`: moved-key floor 15 s → 60 s

Status: settled 20261014T013750Z-8004: cause gone — the walk was over 82 leaked worktrees (944ffc1c) repriced after every commit (review-bench 6c6001e); `review-debt --repo` 2.6 → 0.55-0.8 s with 41 night worktrees, the row ≈ 77 → ~15 CPU-min/day; a 4x lag for ~7 CPU-min/day does not pay, the 15 s floor stays
From: night fixer harness-speed-cpu-statusline-render (20261012T233034Z-3131).

`cpu:statusline/debt` was 77 CPU-min/day (1460 runs, 2.6 s each). A moved key is asked again once the answer is 15 s
old (`repo_debt_lines`, `bin/statusline.sh`). Proposed: a 60 s floor, ~45 % of the row, from the gap histogram.
