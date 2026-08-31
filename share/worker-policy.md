# Worker routing policy

Which ACCOUNT to use is not a judgment call — `worker-pick` answers it under
`docs/routing-contract.md`, and `NEXT:` is the answer. What follows is only the part no
table can decide: which vendor and how much effort a task deserves.

- Prefer Codex for design and well-specified implementation, especially when speed matters. Do not route animation work to Codex; the Fable side is stronger for animation.
- Use Codex effort `medium` for ordinary tasks and `high` for genuinely complex work.
- Prefer claudeb for long or multi-step tasks and work that depends heavily on repository conventions.
- Gemini/Antigravity is a full implementation worker selectable with `worker=gemini`; its base profile is `main`, and named profiles are isolated by `geminib`.
- In auto mode, treat a healthy Gemini reading as an eligible candidate but route conservatively until task-quality and reliability benchmarks establish a stronger weight.
- Grok/SuperGrok is a full implementation worker selectable with `worker=grok`; every account is a named profile isolated by `grokb`, and there is no usable base profile — the real `~/.grok` carries no login.
- In auto mode, treat a healthy Grok reading as an eligible candidate but route conservatively until task-quality and reliability benchmarks establish a stronger weight; it spends one weekly pool shared with Chat and Imagine, so a long run costs Egor more than the percentage suggests.
- Use the account, model, and effort exactly as `NEXT:` prints them; per-task `MODEL:`/`EFFORT:` overrides belong in the brief. The canonical knob-to-agy mapping lives in `worker-run`.
- Codex and Gemini `main` profiles rank last on a tie: an account that spends no more quota than `main` is preferred to it.
- claudeb sonnet runs at effort high or above — sonnet·medium and below are never used; opus may run at medium.
- Code reviews: the chat picks the tier itself (task importance first, then diff complexity; T0 is the floor) and cell composition comes from `review-bench tiers`, never from prose; the human-side rules live in `~/.claude/docs/review-tiers.md`.
