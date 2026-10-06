# A worktree a run creates after launch reads as an escape

Status: settled 20261006T032009Z-f253: granted — a worktree absent from the launch listing that the run's own `worktree add` names joins meta.worktrees_made, read by llm-doctor as a grant

To: `share/doctor-ledger.json` `owners.workers`.

Purpose: `bin/worker-run` grants a run what it may write (`brief_add_dirs`, `brief_worktree_roots`,
`resumed_add_dirs`); `bin/llm-doctor` reads a write outside the grants as `escaped` (ledger W3, W5, W7).

`claudeb-1791165484-91389-3bc4` (2026-10-05, llm-legs suite speed) ran `git worktree add
.claude/worktrees/tmp-suite-speed-baseline-claudeb` from the main checkout, edited a test there and
removed it; W3 read regressed. A worktree another chat creates mid-run stays ungranted.
