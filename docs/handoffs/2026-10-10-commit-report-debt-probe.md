# Hand-off: commit-report's debt probe waits out its budget

Status: closed 2026-10-21 — the commit report no longer asks for the repository's debt (Egor: the row is noise); the probe is gone with it
To: «Review-bench improvements phase 4», /Volumes/Work/Projects/review-bench (next night's fixer if it is not live)

A landing asks `review-debt --repo <top> --split` within the 4 s row budget (claude-setup
`hooks/commit-report.sh`). llm-legs with 48 checkouts: 4-5 s at load ~90, cache missed twice in a row;
cProfile: `price_family` 21 of 27 s, 8 checkouts repriced, 227 git calls. 51 of 100 landings on
2026-10-19 ended at the budget as `debt unknown`. Ask: reprice fewer per call.
