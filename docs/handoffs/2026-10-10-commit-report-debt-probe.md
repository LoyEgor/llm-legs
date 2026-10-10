# Hand-off: commit-report's debt probe waits out its budget

Status: open — To: next night (review-bench)

A landing's block asks `review-debt --repo <top> --split` per repository holding this chat's
leftovers, bounded by what is left of the hook's 4 s row budget (claude-setup
`hooks/commit-report.sh` uncommitted_lines). The cache stamp holds every family checkout's HEAD, so
right after a commit it always misses: 76-82 s for llm-legs, 15 s for claude-setup (load ~39,
2026-10-10). The probe is killed, the row reads `debt unknown`, and each such landing pays ~4.5 s:
197 commit-report runs over 4.5 s on 2026-10-08..09, about 10 min/day.

1. review-bench: profile the post-commit miss (`repo_stamp` walks `dirty_paths` of every family
   checkout; `repo_debt_summary`) and make the `--split` answer cheap after a commit, same number.
2. Only if 1 cannot: a trade to Egor, dropping the debt row from the commit block (the statusline
   already shows repository debt). Ledger row `speed-hook-commit-report`.
