# Worker routing policy

- Prefer Codex for design and well-specified implementation, especially when speed matters. Do not route animation work to Codex; the Fable side is stronger for animation.
- Use Codex effort `medium` for ordinary tasks and `high` for genuinely complex work.
- Prefer claudeb for long or multi-step tasks and work that depends heavily on repository conventions.
- Gemini/Antigravity is a full implementation worker selectable with `worker=gemini`; its base profile is `main`, and named profiles are isolated by `geminib`.
- In auto mode, treat a healthy Gemini reading as an eligible candidate but route conservatively until task-quality and reliability benchmarks establish a stronger weight.
- Use Gemini `ACCOUNT`/`MODEL`/`EFFORT` exactly as `NEXT:` prints them; `gemini_profile=` is an explicit account pin, and the canonical knob-to-agy mapping lives in `~/.claude/agents/gemini-worker.md`.
- When Codex is FRESH, route roughly five of every ten suitable tasks to Codex. Reduce that share as the data-driven verdict tightens.
- Use the claudeb model and effort exactly as `NEXT:` prints them — R8 may have stepped them one rung down the ladder `opus·high → opus·medium → sonnet·high` to spare an account's Fable quota; override upward only when the task genuinely needs it.
- claudeb sonnet runs at effort high or above — sonnet·medium and below are never used; opus may run at medium.
- Always use the concrete account and pre-reset cap from `NEXT:`. Never route a worker to the session account.
- Treat the Codex and Gemini `main` profiles as last-resort: every usable non-main account of the same vendor ranks ahead of its `main`.
- Account selection is headroom-dominant for non-Fable work: prefer the account with the most 5h effective headroom to balance spend across accounts. Small-tier accounts (olx, $20/month) are full citizens for any non-Fable task at any effort.
- Headroom cannot exceed HEADROOM_PCT (90%); if all candidates are above it, pick the least-burnt and note `WARN` in `NEXT`.
- Multi-rater benchmarks re-check affordability before EACH rater and refresh stale account data to prevent re-selecting an exhausted account.
- Code reviews run in benchmarked tiers: T0 quick = codex sol `low`; T1 default = sol `low` + claudeb opus `low` running /code-review, in parallel; T2 quality/risky diffs = sol `high` + opus `medium` /code-review. haiku and sonnet raters never; fable rater only on the user's explicit ask. Codex walled → the opus skill rater first, sol after reset. Skip review only for trivially unambiguous diffs.
