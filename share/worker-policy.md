# Worker routing policy

Which ACCOUNT to use is not a judgment call — `worker-pick` answers it under
`docs/routing-contract.md`, and the `ACCOUNT:` line under its ranked `NEXT` rows is the answer. Which VENDOR is not one either: in
`auto` a vendor a usable workers pin answered leads, then the vendors are ordered by the daily
budget of the account each one selected, and Egor's menu toggles are the only other say. What is left here is the part no table decides — how much
effort a task deserves, and the vendor shapes a brief has to know.

- Use Codex effort `medium` for ordinary tasks and `high` for genuinely complex work.
- Gemini/Antigravity is a full implementation worker selectable with `worker=gemini`; its base profile is `main`, and named profiles are isolated by `geminib`.
- Grok/SuperGrok is a full implementation worker selectable with `worker=grok`; every account is a named profile isolated by `grokb`, and there is no usable base profile — the real `~/.grok` carries no login. It spends one weekly pool shared with Chat and Imagine, so a long run costs Egor more than the percentage suggests.
- **A worker never runs a cheap model.** One model per vendor: claudeb `opus`, codex `gpt-5.6-sol`, gemini `pro`, grok `auto` (`grok-4.6`, the one model it has). No sonnet, haiku or fable; no Terra or Luna; no flash. A worker is dispatched to spend another account's quota on real work, and a run that comes back needing redoing costs more than the cheap model saved. `share/worker-model.sh` holds the list, `worker-run` refuses anything else with `OUTCOME: MODEL_REFUSED` before an account is spent, and the `/worker` toggle refuses to store one — so a `MODEL:` line in a brief can only ever repeat what the vendor already runs, and belongs nowhere. If a task really seems to want another model, that is a question for Egor.
- Use the account and effort exactly as the first `NEXT` row prints them; a per-task `EFFORT:` override belongs in the brief. The canonical knob-to-agy mapping lives in `worker-run`.
- Code reviews: the chat picks the tier itself (task importance first, then diff complexity; T0 is the floor) and cell composition comes from `review-bench tiers`, never from prose; the human-side rules live in `~/.claude/docs/review-tiers.md`.
