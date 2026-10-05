# Hand-off: hook cuts left by night fixer harness-hooks-20261005T061324Z-2ae0

Status: open

## 1. review-anchors store of logo-vectorizer-bench — To: next night (review-bench)

Rows `hook-p50-commit-journal`, `hook-sync-commit-journal`, `hook-every-call-commit-journal`.
`logo-vectorizer-bench/.git/review-anchors.json` is 27 MB: 79 743 anchors, 79 663 touched paths,
most of them bench outputs now gitignored (`results/lanes` 35 887; ≥ 49 870 ignored, 3 350 gone).
Each `review-anchors touch` (claude-setup `hooks/commit-journal.sh:882`) loads and rewrites it
whole. The JSON round trip alone costs 0.66 s CPU, so that chat's commit-journal averages 1 383 ms
CPU a run. Ask: review-bench `bin/review-anchors` drops the touches and anchors of paths its own
`ignored()` rule drops (never debt). Done when the file is under 1 MB and a touch there costs under
50 ms CPU.

## 2. Snapshot fork floor — To: next night (claude-setup)

Rows `hook-sync-review-flow-gate`, `hook-sync-commit-journal`. The owner's named cut no longer
applies: an untracked-cache or fsmonitor status, or skipping trees over a size. Every registered
tree's `git status` now costs about 10 ms CPU, since logo-vectorizer-bench ignores its outputs (64
dirty paths). What stays is `rj_snapshot_content`'s forks per repository (claude-setup
`hooks/lib/review-journal.sh`): cksum, two `rev-parse`, `git status | tr | awk`, `wc`, `mv`, `ln`,
`mv`, plus one `find` per call. The cleanup chat runs review-flow-gate at 764 ms CPU over its 4
repositories, and read-only calls exit at about 30 ms. Ask: fewer forks per repository (one
`rev-parse` for HEAD and the git dir, builtins for the counts), with a fork-count test that is red
on the old code.

## 3. Load-judged rows — To: Harness Doctor

- `hook-p50-stop-dispatch`: 671 ms CPU against 3.5 s wall at load 318. The biggest part is
  ask-run-unfinished at 159 ms CPU (1.0 s wall); the rest are ≤ 70 ms each.
- `hook_sync:context-nudge.sh`: 53 ms CPU against 220 ms wall.
- `statusline:render`: 306 ms CPU p50 (p90 378) and 1.19 s mean wall. `refreshInterval: 3` across
  about 8 chats made 127k renders in 14.4 h today, 11.1 CPU-hours: about 0.77 of a core, 8% of the
  machine.

Proposal: dismiss the first two to load, once hook_p50/hook_sync is judged per load band or on CPU
(the 2026-10-04 proposal).

For the statusline, a trade to bring to Egor:

Cost: a 10 s `refreshInterval` cuts that CPU about 3×. The timer-driven segments (clock, limits)
then lag by up to 10 s.
Loss: if it stays at 3 s, the renders keep holding about 0.77 of a core, which feeds the load
behind every wall-clock row above.
Recommendation: first a night fixer profiles the render and memoizes its dearest segments on their
inputs (`docs/statusline-contract.md`). Bring the interval to Egor only if that falls short.
