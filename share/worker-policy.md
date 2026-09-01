# Worker routing policy

Which ACCOUNT to use is not a judgment call — `worker-pick` answers it under
`docs/routing-contract.md`, and `NEXT:` is the answer. Which VENDOR is not one either: in
`auto` the vendors are ordered by the daily budget of the account each one selected, and Egor's
menu toggles are the only other say. What is left here is the part no table decides — how much
effort a task deserves, and the vendor shapes a brief has to know.

- Use Codex effort `medium` for ordinary tasks and `high` for genuinely complex work.
- Gemini/Antigravity is a full implementation worker selectable with `worker=gemini`; its base profile is `main`, and named profiles are isolated by `geminib`.
- Grok/SuperGrok is a full implementation worker selectable with `worker=grok`; every account is a named profile isolated by `grokb`, and there is no usable base profile — the real `~/.grok` carries no login. It spends one weekly pool shared with Chat and Imagine, so a long run costs Egor more than the percentage suggests.
- Use the account, model, and effort exactly as `NEXT:` prints them; per-task `MODEL:`/`EFFORT:` overrides belong in the brief. The canonical knob-to-agy mapping lives in `worker-run`.
- claudeb sonnet runs at effort high or above — sonnet·medium and below are never used; opus may run at medium.
- Code reviews: the chat picks the tier itself (task importance first, then diff complexity; T0 is the floor) and cell composition comes from `review-bench tiers`, never from prose; the human-side rules live in `~/.claude/docs/review-tiers.md`.
