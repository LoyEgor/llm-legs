# Hand-off: why every tool call took 10 s, and what else slows the machine

Status: done 2026-10-04 — hook-every-call-instruction-watch, hook-sync-instruction-watch-check, guards-baseline-missing-probe-sids, load-unseen-suites-statusline, load-busy-night-concurrency, loose-objects-logo-vectorizer-bench, floor-bash-other-hooks, floor:tool

Closed by «Harness Doctor», 2026-10-04. Every open point was re-verified against the code and the
commits; the full 2026-09-28 analysis is in git history (this file at llm-legs@d9f71640).

- Fixed: the 10 s `instruction-watch.sh check` cancellations and the speed pass (llm-legs@3566f928,
  claude-setup@48bfc77); run-all slots (llm-legs@badbf8ff); llm-legs@c85ff904, @504a065a, @727dddec;
  review-bench@e1db41d; Hammerspoon `routingRefreshPending` coalescing; memlogd fsync; chat-load
  names in-process.
- Tracked: the ledger rows in the Status line, and `2026-09-28-harness-performance-fix.md` §3
  (serial worker-pick in accounts.py, snapshot_other_families, chat-find).
- Closed without a row:
  - Opus 5.5 API speed per model and day belongs to the LLM doctor (docs/harness-doctor-design.md:25,
    docs/speed-doctor-design.md:64).
  - The chat-load fallback at :260 is capped at 3 s (bin/chat-load:251, :293-297).
  - The 2026-09-04..09-15 slow episode is historical, likely claude-setup@a5d98fd. A recurrence is
    now caught by the Waits rule.
- Not this repo's: H8, the review-debt verdict cache under load. It is review-bench's. The harness
  doctor already measures it as the `verdict` sub-run (3 157 s CPU in 4 h).
