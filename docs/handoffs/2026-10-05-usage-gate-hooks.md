# Hand-off: the usage-ai-report LLM gate pays the whole hook stack per call

Status: open

For the next night and the chat «Система вырезания упоминаний о вакансиях», which owns
`/Volumes/Work/Projects/usage-ai-report`. Written 2026-10-05 by night fixer
harness-stop-hooks-20261005T061339Z-2a70 (ledger rows `hook-error-ask-span-drill-budget`,
`hook-error-ask-word-reading-budget`).

`llm_gate.py` `_gate_transports` runs `claudeb -p <prompt> --model sonnet` from cwd `/` as a one-shot
sanitization classifier, and each call loads Egor's full user hook stack. Session 084706a5
(2026-10-04 22:20Z, CPU busy 1.0, swap 9.4 of 10 GB): SessionStart 14.6 + 18.7 s, UserPromptSubmit
5.9 + 6.1 s, Stop 16.1 s (cancelled at the 15 s timeout) against 8.7 s of API time. All 51 cwd-`/`
sessions in the stop journal since 09-28 (~7 a day) are these calls. No hook has work there, and an
ask that blocked would make the classifier answer it instead of returning JSON. That stop spent the
dispatcher's 10 s budget before the word asks ran: the two `budget exhausted` hook-error rows.

Ask: run both transports with hooks off (`--settings '{"disableAllHooks":true}'`; check `claudeb`
passes it through). Done when a gate run adds no cwd-`/` line to
`~/.cache/claude/stop-gate/journal.jsonl` and its transcript has no `hook_` attachment.
