# Vendor release — open items

What a closed event left unproven or blocked, one line each: date, vendor, the claim, what proves it.
An integration chat reads its vendor's lines at entry and, at close, adds what it leaves open and
deletes what it proved by real use or what a newer release made moot. Age alone never removes a
line: an image path nobody has run for two months stays here until a run proves it. Prose, not a
ledger — an approximate line is fine; the end-of-day pass trims what it can confirm.

- 2026-09-23 · codex · which image model serves — cli 0.156.1 output's C2PA says only `ChatGPT / gpt-image` (no version); the source's `IMAGE_MODEL` is gpt-image-2, so only a versioned C2PA or a source change settles a move.
- 2026-09-23 · grok · the model Imagine really serves — the 1.0.41 image_edit C2PA says only "Grok Imagine", so it needs a session-file or response line naming the model.
- 2026-09-23 · claude · 2.1.281 makes a flagged `rm` (command-substitution target, `$VAR/<top-level dir>`, cwd-derived variable) under `--dangerously-skip-permissions` wait 2 minutes, then deny — whether a headless claudeb worker (`-p`) sits out those 2 minutes is unproven; a worker log that hits the denial settles it, and only then is `CLAUDE_CODE_DISABLE_DANGEROUS_RM_TIMEOUT` worth weighing.
