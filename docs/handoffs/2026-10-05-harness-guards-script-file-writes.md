# Guards: a scratchpad script writes relay agents through a run-time path

Status: settled 20261006T032009Z-f253: the owner widened the gate as proposed — a script file run by path and a guarded directory joined to a variable are judged (llm-legs@3b029b93, test_instruction_gate); the five agents rows fixed.

For «Harness Doctor» (`share/harness-ledger.json` `owner`). Written 2026-10-05 by night fixer run
harness-guards-20261005T061312Z-11fb. A gate-scope decision, so the fixer changed no gate. Follows
the closed `2026-10-02-harness-guards-gate-scope.md` (variable path and landing credit, done
2026-10-04; in git history).

## What happened

Rows `guards-growth-claude-agents-{codex,gemini,grok,light}-worker-md`, plus the 2026-10-04T16:35:05Z
event that regressed `guards-growth-claude-agents-claudeb-worker-md`: one watcher event, +147 to
+160 B per file, the fast-forward of claude-setup main to 091caf4 at 16:35:03Z. The bytes were
written at 13:45:47Z in the claude-setup worktree `fix-llm-doctor-handoffs-20261004` by chat
«LLM Doctor меню refactoring». It used a Write of a scratchpad `w7_patch.py`, then Bash
`python3 $S/w7_patch.py`. The script sets `C = "…/agents/"` and writes `open(C + name, "w")`, where
`name` is a dict key. There is no gate record. Six minutes later the same chat's Edit of
`skills/media/SKILL.md` got a bloat `passed`. The watcher prunes worktrees, so the landing is the
first sighting, and the landing credit has no sibling growth to draw on. Each file is over the
120 B bloat threshold, so an Edit would have been denied once for an audit.

## Why no gate saw it

Two shapes are stacked, and design §11 leaves both out of the write gate: the program is a script
FILE named on the command line (the gate reads the command text only), and the name is built at
run time (`C + name`). The same script-file shape appeared before: `python3 land.py … --apply` on
2026-10-03 (row `guards-growth-claude-skills-media`).

## Proposal

It is your call, because it widens what the gate denies. First, the write gate reads a script file
that an interpreter runs by path (`python3|node|perl|ruby <file>`, the first non-option operand,
size-capped) as part of the payload. Second, a quoted literal that is a guarded directory, joined
to a variable (`C + n`, `os.path.join(C, n)`, `Path(C) / n`) and written through a bare
identifier, reads as a write into that directory. False catch: a script that reads such a
directory and writes elsewhere through a variable. That costs one denial, and the retry passes.
Without the change, these rows keep firing when the work lands, once per landed file. The four
rows stay `open` until you decide.
