# Hand-off: a carried handoff about a non-sweep repository has no grant

Status: open

For the «Updater doctor» chat (owner of `bin/night-run`). Written 2026-10-06 by night fixer
llm-workers-20261006T032858Z-6d53 (ledger row W8).

`carry_brief` adds `ADD-DIR:` only for sweep repositories the handoff names, yet its step 1 demands a
fix or a trade and rules out a handoff. Job 2026-10-05-usage-gate-hooks (about
`/Volumes/Work/Projects/usage-ai-report`, no `To:` line) got no grant, so its worker made
`refs/night/20261006T032009Z-f253/base` and a night worktree there itself with
`share/night-worktree.sh`, committed `c86e433`, and the night lands none of it; llm-doctor reads it
as escaped.

Decide one: `carry_list` sends such a handoff to the owner chat it names instead of a job; or
`carry_brief` tells the job the repository is not the night's, so it may only reduce the handoff to
a trade. A test in `tests/test_night_run.sh` with a fixture handoff naming a non-sweep repository.
