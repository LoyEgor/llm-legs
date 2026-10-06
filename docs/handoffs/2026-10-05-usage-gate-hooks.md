# Hand-off: the usage-ai-report LLM gate pays the whole hook stack per call

Status: trade for Egor
Cost: one `git merge c86e433` in usage-ai-report main (3 files, +23/−2, merges clean onto a032549); the night may not land it, the repo is outside `~/.claude/sweep-repos`.
Loss: every gate call (`llm_gate.py` `_gate_transports`, `claudeb -p` from cwd `/`; 32 on 2026-10-05) keeps paying ~50 s of hooks (Stop cancelled at 15 s under load), and a blocking ask can replace the JSON verdict.
Recommendation: merge c86e433, then drop its night worktree and branch.

Written 2026-10-05 by night fixer harness-stop-hooks-20261005T061339Z-2a70 (ledger rows
`hook-error-ask-span-drill-budget`, `hook-error-ask-word-reading-budget`).

Proof: a gate run adds no cwd-`/` line to `~/.cache/claude/stop-gate/journal.jsonl`.
