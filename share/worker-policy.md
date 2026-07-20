# Worker routing policy

- Prefer Codex for design and well-specified implementation, especially when speed matters. Do not route animation work to Codex; the Fable side is stronger for animation.
- Use Codex effort `medium` for ordinary tasks and `high` for genuinely complex work.
- Prefer claudeb for long or multi-step tasks and work that depends heavily on repository conventions.
- When Codex is FRESH, route roughly five of every ten suitable tasks to Codex. Reduce that share as the data-driven verdict tightens.
- Use the claudeb model and effort exactly as `NEXT:` prints them — R8 may have stepped them one rung down the ladder `opus·high → opus·medium → sonnet·high` to spare an account's Fable quota; override upward only when the task genuinely needs it.
- claudeb sonnet runs at effort high or above — sonnet·medium and below are never used; opus may run at medium.
- Always use the concrete account and pre-reset cap from `NEXT:`. Never route a worker to the session account.
