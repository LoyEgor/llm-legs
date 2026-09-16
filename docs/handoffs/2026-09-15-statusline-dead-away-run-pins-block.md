# Hand-off: a dead away run pins the statusline block and hides home debt — SUPERSEDED

Resolved 2026-09-15/16 by the place-journal redesign (llm-legs 0ac5ed4 and the fork/Bash-write/removed-worktree
follow-up): there is no home, away, stickiness, priority or run pin any more. The shown tree is the
tree of the last resolvable line of the chat's place journal, and every write — edit, git write, cd,
dispatch, worker or review start and end — appends a line. `docs/statusline-contract.md`, section
"Shown tree", is the contract; `statusline-place why --session <id>` explains any render.
