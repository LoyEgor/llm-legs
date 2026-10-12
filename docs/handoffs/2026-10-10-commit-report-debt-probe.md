# Hand-off: commit-report's debt probe waits out its budget

Status: settled 20261012T005404Z-e2f7: review-bench@be0b79d price_family memoizes each checkout's price by its own stamp; a worktree commit reprices one checkout (llm-legs, 22 checkouts: 32 s → ~2 s at load 150, same LINES/DUE)

A landing's block asks `review-debt --repo <top> --split` within what is left of the 4 s row budget
(claude-setup `hooks/commit-report.sh` uncommitted_lines). Every commit moved the family stamp, so
all checkouts were repriced: 76-82 s for llm-legs, the probe was killed, the row read `debt unknown`,
~4.5 s per landing (197 runs on 2026-10-08..09, ~10 min/day). Still open: a commit on main moves the
key of every linked checkout, which then reprices (a killed probe now banks what it priced).
